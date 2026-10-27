"""Focused dependency-closure checks; actual DEX fixtures are separately audited with the CLI."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('saf_audit', Path(__file__).with_name('audit-saf-test-apk.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class Platform:
    def definition(self, name):
        if name == 'Ljava/lang/Object;':
            return {'parents': [], 'fields': {}, 'methods': {('toString', '()Ljava/lang/String;'): 1}}
        if name == 'Ljava/lang/String;':
            return {'parents': ['Ljava/lang/Object;'], 'fields': {}, 'methods': {}}


def inventory():
    return {'definitions': {'LProvider;': {'parents': ['Ljava/lang/Object;'], 'fields': {},
            'methods': {('<clinit>', '()V'): 8}}}, 'accesses': [], 'typeAccesses': []}


class ClosureTest(unittest.TestCase):
    def test_platform_inherited_member_is_resolved(self):
        value = inventory()
        value['accesses'].append((('LProvider;', '<clinit>', '()V'), 0, 'methods',
                                  ('Ljava/lang/String;', 'toString', '()Ljava/lang/String;'), False))
        self.assertTrue(audit.linkage(value, Platform(), ['LProvider;'])['passed'])

    def test_missing_synthetic_helper_cannot_hide_a_main_app_dependency(self):
        value = inventory()
        value['definitions']['LSynthetic;'] = {'parents': [], 'fields': {}, 'methods': {('invoke', '()V'): 8}}
        value['accesses'].extend([
            (('LProvider;', '<clinit>', '()V'), 0, 'methods', ('LSynthetic;', 'invoke', '()V'), True),
            (('LSynthetic;', 'invoke', '()V'), 0, 'methods', ('Lkotlin/collections/CollectionsKt;', 'listOf', '()V'), True)])
        result = audit.linkage(value, Platform(), ['LProvider;'])
        self.assertFalse(result['passed'])
        self.assertIn('LSynthetic;', result['reachableTestClasses'])
        self.assertIn('Lkotlin/collections/CollectionsKt;', result['missingTypes'])

    def test_signatures_field_types_and_catch_types_are_dependencies(self):
        value = inventory()
        value['definitions']['LProvider;']['fields'][('field', 'LAppOnly;')] = 0
        value['definitions']['LProvider;']['methods'][('call', '([LArgument;)LResult;')] = 1
        value['typeAccesses'].append((('LProvider;', '<clinit>', '()V'), 'LAppOnlyException;'))
        result = audit.linkage(value, Platform(), ['LProvider;'])
        self.assertEqual(result['missingTypes'], ['LAppOnly;', 'LAppOnlyException;', 'LArgument;', 'LResult;'])

    def test_static_instance_mismatch_and_missing_component_both_fail(self):
        value = inventory()
        value['accesses'].append((('LProvider;', '<clinit>', '()V'), 0, 'methods',
                                  ('Ljava/lang/Object;', 'toString', '()Ljava/lang/String;'), True))
        result = audit.linkage(value, Platform(), ['LProvider;', 'LControl;'])
        self.assertFalse(result['passed'])
        self.assertEqual(result['missingRoots'], ['LControl;'])
        self.assertEqual(len(result['unresolvedOrWrongStaticAccesses']), 1)

    def test_unrelated_instrumentation_app_reference_is_outside_independent_component_scope(self):
        value = inventory()
        value['definitions']['LInstrumentation;'] = {'parents': [], 'fields': {}, 'methods': {('run', '()V'): 1}}
        value['accesses'].append((('LInstrumentation;', 'run', '()V'), 0, 'methods', ('LMainApp;', 'run', '()V'), True))
        self.assertTrue(audit.linkage(value, Platform(), ['LProvider;'])['passed'])


if __name__ == '__main__':
    unittest.main()
