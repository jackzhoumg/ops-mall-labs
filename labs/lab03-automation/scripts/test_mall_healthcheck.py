"""mall_healthcheck.py 纯函数的单元测试。

运行：cd labs/lab03-automation/scripts && python3 -m unittest -v test_mall_healthcheck.py
"""

import base64
import hashlib
import hmac
import json
import unittest
import urllib.parse

import mall_healthcheck as hc


class ParseTargetsTest(unittest.TestCase):
    def test_strip_and_skip_empty(self):
        self.assertEqual(
            hc.parse_targets(" http://a:8080/, ,http://b:8080 ,,"),
            ["http://a:8080", "http://b:8080"],
        )

    def test_empty(self):
        self.assertEqual(hc.parse_targets(""), [])


class EvaluateReadyzTest(unittest.TestCase):
    def test_ready(self):
        body = json.dumps({"ready": True, "checks": {"mysql": "ok", "redis": "ok"}})
        self.assertEqual(hc.evaluate_readyz(200, body), [])

    def test_mysql_down(self):
        body = json.dumps({"ready": False, "checks": {"mysql": "dial tcp: connection refused", "redis": "ok"}})
        self.assertEqual(hc.evaluate_readyz(503, body), ["mysql 不可用: dial tcp: connection refused"])

    def test_non_json_503(self):
        self.assertEqual(hc.evaluate_readyz(503, "<html>bad gateway</html>"), ["/readyz 返回 HTTP 503"])

    def test_connect_failed(self):
        self.assertEqual(hc.evaluate_readyz(0, "connection refused"), ["/readyz 返回 HTTP 0"])


class EvaluateProductsTest(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(hc.evaluate_products(200, '[{"id":1}]'), [])

    def test_empty_list(self):
        self.assertEqual(len(hc.evaluate_products(200, "[]")), 1)

    def test_500(self):
        self.assertEqual(hc.evaluate_products(500, '{"error":"database error"}'), ["/api/products 返回 HTTP 500"])


class ShouldNotifyTest(unittest.TestCase):
    def test_first_run(self):
        self.assertFalse(hc.should_notify(None, True))
        self.assertTrue(hc.should_notify(None, False))

    def test_state_change(self):
        self.assertTrue(hc.should_notify(True, False))   # 告警
        self.assertTrue(hc.should_notify(False, True))   # 恢复

    def test_no_change(self):
        self.assertFalse(hc.should_notify(True, True))
        self.assertFalse(hc.should_notify(False, False))  # 持续异常不刷屏


class PayloadTest(unittest.TestCase):
    def test_wecom(self):
        self.assertEqual(
            hc.build_wecom_payload("hi"),
            {"msgtype": "markdown", "markdown": {"content": "hi"}},
        )

    def test_dingtalk(self):
        p = hc.build_dingtalk_payload("hi", title="t")
        self.assertEqual(p, {"msgtype": "markdown", "markdown": {"title": "t", "text": "hi"}})

    def test_message_contains_problem(self):
        r = hc.CheckResult(target="http://a:8080")
        r.fail("mysql 不可用: timeout")
        text = hc.format_message(r, "lab-web1")
        self.assertIn("告警", text)
        self.assertIn("mysql 不可用: timeout", text)
        self.assertIn("lab-web1", text)


class DingtalkSignTest(unittest.TestCase):
    def test_sign_matches_manual_calculation(self):
        secret, ts = "SECtest", 1700000000000
        expected = urllib.parse.quote_plus(
            base64.b64encode(
                hmac.new(secret.encode(), f"{ts}\n{secret}".encode(), hashlib.sha256).digest()
            ).decode()
        )
        self.assertEqual(hc.dingtalk_sign(secret, ts), expected)

    def test_signed_url(self):
        url = hc.dingtalk_signed_url("https://oapi.dingtalk.com/robot/send?access_token=x", "s", 1)
        self.assertTrue(url.startswith("https://oapi.dingtalk.com/robot/send?access_token=x&timestamp=1&sign="))


if __name__ == "__main__":
    unittest.main()
