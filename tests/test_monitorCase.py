#!/usr/bin/env python3
"""Regression tests for dictionary layouts, mesh logs, and progress reporting."""
import argparse
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'monitorCase'
LOADER = importlib.machinery.SourceFileLoader('monitor_case', str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
monitor = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(monitor)

COMPACT_CONTROL = '''FoamFile
{ version 2.0; format ascii; class dictionary; object controlDict; }
application bubbleSourcePilot;
startFrom startTime; startTime 0; stopAt endTime; endTime 0.11; deltaT 1e-06;
writeControl adjustableRunTime; writeInterval 0.001; purgeWrite 0;
'''


class MonitorTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.case = Path(tmp.name)
        (self.case / 'system').mkdir()
        self.control = self.case / 'system/controlDict'
        self.control.write_text(COMPACT_CONTROL)
        monitor.last_known_metrics.clear()

    def test_compact_control(self):
        for key, expected in {'application': 'bubbleSourcePilot', 'startTime': '0',
                              'endTime': '0.11', 'writeInterval': '0.001'}.items():
            self.assertEqual(monitor.get_control_dict_value(self.case, key), expected)

    def test_multiline_control(self):
        self.control.write_text('application\n simpleFoam;\nendTime\n 20;\n')
        self.assertEqual(monitor.get_foam_application(self.case), 'simpleFoam')
        self.assertEqual(monitor.get_control_dict_value(self.case, 'endTime'), '20')

    def test_comments_nested_entries_and_quoted_delimiters(self):
        self.control.write_text('''// application wrongFoam; endTime 999;
/* endTime 888; // block comment */
FoamFile { endTime 777; }
functions { sample { endTime 666; note "}; endTime 555; //"; } }
libs ("fake; endTime 444; {" { endTime 333; });
#include "missing-file"
application "bubbleSourcePilot"; endTime /* ignored */ 0.11;
writeInterval 0.001; // trailing comment
''')
        self.assertEqual(monitor.get_foam_application(self.case), 'bubbleSourcePilot')
        self.assertEqual(monitor.get_control_dict_value(self.case, 'endTime'), '0.11')
        self.assertEqual(monitor.get_write_interval(self.case), '0.001')

    def test_nested_end_time_is_not_used_as_target(self):
        self.control.write_text('functions { sample { endTime 0.11; } }')
        self.assertIsNone(monitor.get_control_dict_value(self.case, 'endTime'))

    def test_code_and_variables_are_not_evaluated(self):
        self.control.write_text('''functions { x { code #{ endTime 999; } #{ #}; } }
endTime $target; writeInterval #calc "1 + 2";
application bubbleSourcePilot;
''')
        self.assertIsNone(monitor.get_control_dict_value(self.case, 'endTime'))
        self.assertIsNone(monitor.get_write_interval(self.case))
        self.assertEqual(monitor.get_foam_application(self.case), 'bubbleSourcePilot')

    def test_mesh_type_uses_shared_reader(self):
        (self.case / 'constant').mkdir()
        dictionary = self.case / 'constant/dynamicMeshDict'
        dictionary.write_text('FoamFile { object dynamicMeshDict; } dynamicFvMesh dynamicRefineFvMesh;')
        self.assertEqual(monitor.get_mesh_type(self.case), 'Dynamic (AMR)')
        dictionary.write_text('dynamicFvMesh staticFvMesh;')
        self.assertEqual(monitor.get_mesh_type(self.case), 'Static')

    def mesh_log(self, relative, cells, status='Mesh OK.', mtime=100):
        path = self.case / relative
        path.parent.mkdir(exist_ok=True)
        path.write_text(f'Mesh stats\n    cells: {cells}\n{status}\n')
        os.utime(path, (mtime, mtime))
        return path

    def test_both_mesh_log_locations(self):
        for location in ('log.checkMesh', 'log/log.checkMesh'):
            with self.subTest(location=location):
                path = self.mesh_log(location, 2576384)
                self.assertEqual(monitor.get_mesh_info(self.case), ('OK', '2 576 384'))
                path.unlink()

    def test_newest_mesh_log_wins(self):
        for newer in ('log.checkMesh', 'log/log.checkMesh'):
            with self.subTest(newer=newer):
                for location in ('log.checkMesh', 'log/log.checkMesh'):
                    self.mesh_log(location, 100, mtime=100)
                self.mesh_log(newer, 200, 'Failed 1 mesh checks.', mtime=200)
                self.assertEqual(monitor.get_mesh_info(self.case), ('Failed', '200'))

    def test_unreadable_newest_log_falls_back(self):
        self.mesh_log('log.checkMesh', 100, mtime=100)
        newest = self.mesh_log('log/log.checkMesh', 200, mtime=200)
        original_open = open

        def selective_open(path, *args, **kwargs):
            if Path(path) == newest:
                raise PermissionError(path)
            return original_open(path, *args, **kwargs)

        with patch('builtins.open', side_effect=selective_open):
            self.assertEqual(monitor.get_mesh_info(self.case), ('OK', '100'))

    def render(self, full=True, current=0.0845):
        log = self.case / 'log.solve'
        log.write_text('Time = 0.0844\nExecutionTime = 10 s\n'
                       'deltaT = 0.0001\nTime = 0.0845\nExecutionTime = 20 s\n')
        with patch.object(monitor, 'get_openfoam_processes', return_value={
                (str(self.case), 'bubbleSourcePilot'): list(range(100, 114))}), \
             patch.object(monitor, 'get_active_log_file', return_value=str(log)), \
             patch.object(monitor, 'get_current_time', return_value=current), \
             patch.object(monitor, 'get_elapsed_time', return_value=3600):
            return '\n'.join(monitor.build_output(argparse.Namespace(full=full)))

    def test_full_output_restores_progress_and_mesh_details(self):
        self.mesh_log('log.checkMesh', 2576384)
        out = self.render()
        for expected in ('bubbleSourcePilot', 'Parallel (14 cores)', '0.11 s',
                         '0.001 s', '2 576 384', '184 027', '76.8%', 'ETA: 00:42:'):
            self.assertIn(expected, out)
        self.assertAlmostEqual(monitor.last_known_metrics[(str(self.case), 100)]['eta_sec'], 2550)

    def test_missing_or_invalid_target_has_no_eta_in_either_view(self):
        for full in (False, True):
            for target in ('', 'endTime invalid;', 'endTime nan;', 'endTime inf;'):
                with self.subTest(full=full, target=target):
                    # First populate a valid ETA to check that it is cleared.
                    self.control.write_text(COMPACT_CONTROL)
                    self.assertIn('ETA: 00:42:', self.render(full))
                    self.control.write_text('application bubbleSourcePilot; ' + target)
                    out = self.render(full)
                    self.assertIn('ETA: Unavailable', out)
                    self.assertNotIn('ETA: 00:00:00', out)

    def test_zero_eta_requires_reaching_target(self):
        for current in (0.11, 0.12):
            with self.subTest(current=current):
                self.assertIn('ETA: 00:00:00', self.render(current=current))

    def test_no_measured_speed_clears_previous_eta(self):
        self.assertIn('ETA: 00:42:', self.render())
        with patch.object(monitor, 'get_log_metrics', return_value={
                **monitor.get_log_metrics(None), 't': [0.0845], 'exec': [20]}):
            self.assertIn('ETA: Unavailable', self.render())


if __name__ == '__main__':
    unittest.main()
