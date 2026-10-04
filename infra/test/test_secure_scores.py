import importlib.util
from pathlib import Path
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location("secure_scores", Path(__file__).parents[1] / "secure_scores.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


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
