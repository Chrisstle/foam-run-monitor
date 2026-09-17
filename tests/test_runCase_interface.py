#!/usr/bin/env python3
"""Read-only and fail-closed interface tests using the sourced OpenFOAM tools."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'runCase'
HEADER = 'FoamFile { version 2.0; format ascii; class dictionary; object controlDict; }\n'
FIELD = 'FoamFile { version 2.0; format ascii; class volVectorField; object U; }\ninternalField uniform (0 0 0);\n'

class InterfaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.case = Path(self.tmp.name)
        (self.case/'system').mkdir()
        self.control()
        for time in ('0', '1'):
            (self.case/time).mkdir()
            (self.case/time/'U').write_text(FIELD)

    def control(self, start='latestTime', end='2'):
        (self.case/'system/controlDict').write_text(HEADER + f'application icoFoam;\nstartFrom {start};\nendTime {end};\nwriteInterval 1;\n')

    def run_case(self, *args, code=0):
        result = subprocess.run([str(SCRIPT), *args], cwd=self.case, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=15, env=getattr(self, "env", None))
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return sorted((str(p.relative_to(self.case)), hashlib.sha256(p.read_bytes()).hexdigest())
                      for p in self.case.rglob('*') if p.is_file())

    def test_plan_is_read_only(self):
        before = self.snapshot()
        plan = json.loads(self.run_case('--continue', '--plan', '--format=json').stdout)
        self.assertTrue(plan['ok'])
        self.assertEqual(plan['latestTime'], 1)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.case/'.runCase').exists())

    def test_cleanup_fails_immediately_without_mutation(self):
        before = self.snapshot()
        result = self.run_case('--new', '--quiet', '--non-interactive', code=11)
        self.assertIn('CLEANUP_REQUIRED', result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.case/'log').exists())

    def test_clean_requires_approval(self):
        self.run_case('--clean', '--non-interactive', code=11)
        self.assertTrue((self.case/'1/U').exists())

    def test_invalid_start(self):
        self.control(start='startTime')
        data = json.loads(self.run_case('--continue', '--plan', '--format=json', code=12).stdout)
        self.assertEqual(data['error'], 'INVALID_RESTART')

    def test_end_time(self):
        self.control(end='1')
        self.run_case('--continue', '--non-interactive', code=12)

    def test_missing_field(self):
        (self.case/'0/p').write_text(FIELD.replace('volVectorField', 'volScalarField'))
        result = self.run_case('--continue', '--plan', code=12)
        self.assertIn('Missing initialized fields', result.stderr)

    def test_parallel_time_mismatch(self):
        (self.case/'system/decomposeParDict').write_text('numberOfSubdomains 2;\n')
        for rank, time in ((0, '1'), (1, '0.5')):
            dest = self.case/f'processor{rank}'/time
            dest.mkdir(parents=True)
            (dest/'U').write_text(FIELD)
        result = self.run_case('--continue', '--plan', code=12)
        self.assertIn('disagree', result.stderr)

    def test_invalid_arguments(self):
        self.run_case('--new', '-np', '0', code=2)
        self.run_case('--new', '-P', '0', code=2)
        self.run_case('--continue', '--allow-clean', code=2)

    def test_live_lock(self):
        import fcntl
        (self.case/'.runCase').mkdir()
        with (self.case/'.runCase/lock').open('w') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_case('--continue', '--quiet', '--non-interactive', code=13)
            self.assertIn('ALREADY_RUNNING', result.stderr)

    def test_capabilities(self):
        result = json.loads(self.run_case('--capabilities').stdout)
        self.assertEqual(result['interfaceVersion'], 1)

    def fake_tools(self, mesh_status=0, mesh_text='Mesh OK.', solver_status=0, decomp_status=0):
        self.bin = self.case/'bin'
        self.bin.mkdir(exist_ok=True)
        scripts = {
            'icoFoam': f'echo solver >> calls; exit {solver_status}',
            'checkMesh': f'echo "mesh $*" >> calls; echo "{mesh_text}"; exit {mesh_status}',
            'decomposePar': f'echo "decompose $*" >> calls; exit {decomp_status}',
            'mpirun': 'shift 2; exec "$@"',
        }
        for name, body in scripts.items():
            target = self.bin/name
            target.write_text('#!/bin/bash\n'+body+'\n')
            target.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'])

    def test_success_receipt_and_stale_lock(self):
        self.fake_tools()
        (self.case/'.runCase').mkdir()
        (self.case/'.runCase/lock').touch()
        (self.case/'.runCase/last-run.json').write_text('{"state":"running","pid":99999999}')
        plan = json.loads(self.run_case('--continue', '--plan', '--format=json').stdout)
        self.assertIn('kernel lock is free', plan['warnings'][0])
        self.run_case('--continue', '--quiet', '--non-interactive')
        receipt = json.loads((self.case/'.runCase/last-run.json').read_text())
        self.assertEqual(receipt['state'], 'completed')
        self.assertEqual(receipt['exitStatus'], 0)
        self.assertEqual(receipt['solver'], 'icoFoam')
        self.assertEqual(receipt['restartTime'], '1')
        self.assertIsInstance(receipt['solverPid'], int)
        self.assertLessEqual(receipt['startedAt'], receipt['updatedAt'])
        self.assertEqual((self.case/'calls').read_text().splitlines(), ['mesh -latestTime', 'solver'])
        # A leftover lock file must not prevent another invocation.
        self.run_case('--continue', '--quiet', '--non-interactive')

    def test_mesh_failure_stops_solver(self):
        self.fake_tools(mesh_status=1)
        self.run_case('--continue', '--quiet', '--non-interactive', code=20)
        self.assertNotIn('solver', (self.case/'calls').read_text())
        receipt = json.loads((self.case/'.runCase/last-run.json').read_text())
        self.assertEqual(receipt['error'], 'MESH_FAILED')
        self.assertEqual(receipt['exitStatus'], 20)

    def test_bad_mesh_success_exit_stops_solver(self):
        self.fake_tools(mesh_text='Failed 1 mesh checks.')
        self.run_case('--continue', '--quiet', '--non-interactive', code=20)
        self.assertNotIn('solver', (self.case/'calls').read_text())

    def test_solver_failure(self):
        self.fake_tools(solver_status=9)
        result = self.run_case('--continue', '--quiet', '--non-interactive', code=30)
        self.assertIn('status 9', result.stderr)
        self.assertEqual(json.loads((self.case/'.runCase/last-run.json').read_text())['exitStatus'], 30)

    def test_decomposition_failure(self):
        self.fake_tools(decomp_status=1)
        (self.case/'system/decomposeParDict').write_text('numberOfSubdomains 2;\n')
        self.run_case('--continue', '--quiet', '--non-interactive', code=14)
        calls = (self.case/'calls').read_text()
        self.assertIn('decompose -latestTime', calls)
        self.assertNotIn('solver', calls)

    def test_parallel_mesh_checks_restart(self):
        self.fake_tools(mesh_status=1)
        (self.case/'system/decomposeParDict').write_text('numberOfSubdomains 2;\n')
        for rank in (0, 1):
            dest = self.case/f'processor{rank}/1'
            dest.mkdir(parents=True)
            (dest/'U').write_text(FIELD)
        self.run_case('--continue', '--quiet', '--non-interactive', code=20)
        self.assertIn('mesh -parallel -latestTime', (self.case/'calls').read_text())

    def test_rank_override_plan_does_not_edit(self):
        dictionary = self.case/'system/decomposeParDict'
        dictionary.write_text('numberOfSubdomains 2;\n')
        before = self.snapshot()
        result = json.loads(self.run_case('--new', '--plan', '--np', '4', '--format=json').stdout)
        self.assertEqual(result['ranks'], 4)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(result['requiresConfirmation'])
        self.assertEqual(result['decomposition'], 'create')

    def test_conflicting_and_missing_options(self):
        for args in [('--new', '--continue'), ('--new', '--fps'), ('--new', '--res', '10'),
                     ('--new', '--state'), ('--new', '--format=json')]:
            self.run_case(*args, code=2)

    def test_read_only_function_entry(self):
        # If evaluated, #calc runs its codeStream compiler and writes dynamicCode.
        self.control(end='#calc "1+1"')
        self.run_case('--continue', '--plan', '--format=json', code=15)
        self.assertFalse((self.case/'dynamicCode').exists())

    def test_batch_plan_is_json_lines_without_mutation(self):
        before = self.snapshot()
        result = self.run_case('--continue', '--plan', '--format=json', str(self.case))
        self.assertTrue(json.loads(result.stdout)['ok'])
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.case/'log').exists())

    def test_explicit_clean(self):
        self.run_case('--clean', '--non-interactive', '--allow-clean')
        self.assertFalse((self.case/'1').exists())
        self.assertTrue((self.case/'0/U').exists())
        self.assertEqual(json.loads((self.case/'.runCase/last-run.json').read_text())['state'], 'completed')

    def test_setfields_failure(self):
        self.fake_tools()
        (self.case/'system/setFieldsDict').write_text('// intentionally stubbed\n')
        script = self.bin/'setFields'
        script.write_text('#!/bin/bash\nexit 1\n')
        script.chmod(0o755)
        self.run_case('--new', '--allow-clean', '--non-interactive', '--quiet', code=15)
        self.assertNotIn('solver', (self.case/'calls').read_text())

    def test_no_initial_field_inventory(self):
        (self.case/'0/U').unlink()
        result = self.run_case('--continue', '--plan', code=12)
        self.assertIn('No initial field inventory', result.stderr)

    def test_lock_held_during_solver(self):
        import time
        self.fake_tools()
        (self.bin/'icoFoam').write_text('#!/bin/bash\ntouch solver-started\nsleep 2\n')
        process = subprocess.Popen([str(SCRIPT), '--continue', '--non-interactive', '--quiet'],
                                   cwd=self.case, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if (self.case/'solver-started').exists(): break
                time.sleep(.05)
            self.assertTrue((self.case/'solver-started').exists())
            self.run_case('--continue', '--non-interactive', '--quiet', code=13)
            self.assertEqual(process.wait(timeout=10), 0)
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=10)
            process.stderr.close()

    def test_noninteractive_batch(self):
        self.fake_tools()
        self.run_case('--continue', '--non-interactive', '--quiet', str(self.case))
        self.assertEqual(json.loads((self.case/'.runCase/last-run.json').read_text())['state'], 'completed')

    def test_sigterm_receipt(self):
        import time
        self.fake_tools()
        (self.bin/'icoFoam').write_text('#!/bin/bash\ntouch solver-started\nexec sleep 30\n')
        process = subprocess.Popen([str(SCRIPT), '--continue', '--non-interactive', '--quiet'],
                                   cwd=self.case, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if (self.case/'solver-started').exists(): break
                time.sleep(.05)
            self.assertTrue((self.case/'solver-started').exists())
            process.terminate()
            self.assertEqual(process.wait(timeout=10), 143)
            receipt = json.loads((self.case/'.runCase/last-run.json').read_text())
            self.assertEqual(receipt['error'], 'INTERRUPTED')
            self.assertEqual(receipt['exitStatus'], 143)
            self.assertTrue((self.case/'1/U').exists())
        finally:
            if process.poll() is None: process.kill(); process.wait(timeout=10)
            process.stderr.close()

if __name__ == '__main__':
    unittest.main()
