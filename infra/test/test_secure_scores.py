import importlib.util
from pathlib import Path
import re
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location("secure_scores", Path(__file__).parents[1] / "secure_scores.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CanonicalPaths(unittest.TestCase):
    def allowed(self, path):
        # Evaluate the actual generated path predicate. Adapt only the small
        # Rules-language subset used here; keep byte-indexed substring semantics.
        expression = module.canonical_path_expression().replace("raw.http.request.uri.path", "path")
        for operator, python in {"eq": "==", "ne": "!=", "ge": ">=", "le": "<="}.items():
            expression = re.sub(rf"\b{operator}\b", python, expression)
        expression = re.sub(r'"\s+"', '\", \"', expression)
        functions = {
            "path": path,
            "len": lambda value: len(value.encode()),
            "starts_with": str.startswith,
            "ends_with": str.endswith,
            "substring": lambda value, start, end: value.encode()[start:end].decode("latin1"),
            "remove_bytes": lambda value, removed: value.translate(str.maketrans("", "", removed)),
        }
        return eval(expression, {"__builtins__": {}}, functions)

    def test_accepts_canonical_paths(self):
        for path in ["/catalog.json", "/fixtures-2026-10-04.json", "/fixtures-2028-02-29.json",
                     "/matches/1.json", "/matches/1565179.json", "/matches/9999999999999999.json"]:
            with self.subTest(path=path):
                self.assertTrue(self.allowed(path))

    def test_rejects_noncanonical_paths(self):
        for path in ["/fixtures-aaaaaaaaaa.json", "/fixtures-2026-00-04.json",
                     "/fixtures-2026-13-04.json", "/fixtures-2026-10-00.json",
                     "/fixtures-2026-10-32.json", "/fixtures-2026/10/04.json",
                     "/fixtures-0000-01-01.json", "/fixtures-2026-1-01.json",
                     "/matches/.json", "/matches/not-a-number.json", "/matches/nested/x.json",
                     "/matches/0.json", "/matches/01.json", "/matches/-1.json",
                     "/matches/1.0.json", "/matches/1e3.json", "/matches/1.json/",
                     "/matches/99999999999999999.json", "/matches/١.json",
                     "/matches/%31.json", "/matches/%2531.json", "/matches/../catalog.json",
                     "//catalog.json", "/catalog.json/", "/CATALOG.JSON", "/%63atalog.json"]:
            with self.subTest(path=path):
                self.assertFalse(self.allowed(path))

    def test_rule_includes_predicate_and_fits_expression_limit(self):
        expression = module.rule()["expression"]
        self.assertIn("not " + module.canonical_path_expression(), expression)
        self.assertLessEqual(len(expression), 4096)


class RulesetSafety(unittest.TestCase):
    def test_updates_only_managed_rule_without_replacing_emergency_controls(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            return {"id": "entry", "rules": [{"id": "stop", "ref": "emergency-stop"},
                                              {"id": "ours", "ref": module.REF}]}
        module.apply(api, "zone")
        self.assertEqual(calls[1][:2], ("PATCH", "/zones/zone/rulesets/entry/rules/ours"))
        self.assertNotIn("rules", calls[1][2])
        self.assertEqual(calls[1][2]["position"], {"before": ""})

    def test_adds_to_existing_ruleset_without_overwriting_it(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            return {"id": "entry", "rules": [{"id": "stop", "ref": "emergency-stop"}]}
        module.apply(api, "zone")
        self.assertEqual(calls[1][:2], ("POST", "/zones/zone/rulesets/entry/rules"))

    def test_permission_failure_never_falls_back_to_creation(self):
        calls = []
        def api(method, path, body=None):
            calls.append(method)
            raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            module.apply(api, "zone")
        self.assertEqual(calls, ["GET"])

    def test_creates_only_when_entrypoint_is_absent(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            if method == "GET":
                raise urllib.error.HTTPError(path, 404, "not found", {}, None)
        module.apply(api, "zone")
        self.assertEqual(calls[1][2]["rules"], [module.rule()])


if __name__ == "__main__":
    unittest.main()
