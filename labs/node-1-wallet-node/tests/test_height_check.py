"""height_check.py 的单元测试，不联网。运行：python3 -m pytest -q 或 python3 -m unittest discover -s tests"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import height_check as hc  # noqa: E402

NOW = 1_800_000_000


def resp(height, ts, syncing=False, peers="0x19", chain="0x88bb0"):
    return [
        {"jsonrpc": "2.0", "id": 1, "result": {"number": hex(height), "timestamp": hex(ts)}},
        {"jsonrpc": "2.0", "id": 2, "result": syncing},
        {"jsonrpc": "2.0", "id": 3, "result": peers} if peers else
        {"jsonrpc": "2.0", "id": 3, "error": {"code": -32601, "message": "method not found"}},
        {"jsonrpc": "2.0", "id": 4, "result": chain},
    ]


class HeightCheckTest(unittest.TestCase):
    def test_parse_hex(self):
        self.assertEqual(hc.parse_hex("0x10"), 16)
        self.assertEqual(hc.parse_hex(7), 7)
        with self.assertRaises(ValueError):
            hc.parse_hex("16")

    def test_parse_endpoint(self):
        self.assertEqual(hc.parse_endpoint("a=http://x:8545"), ("a", "http://x:8545"))
        for bad in ("noequals", "a=ftp://x", "=http://x"):
            with self.assertRaises(Exception):
                hc.parse_endpoint(bad)

    def test_interpret_ok_and_out_of_order(self):
        r = hc.interpret("n", "local", "u", list(reversed(resp(100, NOW - 12))))
        self.assertTrue(r.up)
        self.assertEqual((r.height, r.peers, r.chain_id, r.syncing), (100, 25, 560048, False))

    def test_interpret_reference_without_peer_count(self):
        r = hc.interpret("ref", "reference", "u", resp(100, NOW, peers=None))
        self.assertTrue(r.up)
        self.assertEqual(r.peers, -1)

    def test_interpret_error(self):
        r = hc.interpret("n", "local", "u", [{"id": 1, "error": {"message": "boom"}}])
        self.assertFalse(r.up)
        self.assertIn("boom", r.error)

    def test_healthy(self):
        res = [hc.interpret("a", "local", "u", resp(1000, NOW - 10)),
               hc.interpret("b", "local", "u", resp(999, NOW - 20)),
               hc.interpret("ref", "reference", "u", resp(1001, NOW - 5, peers=None))]
        self.assertEqual(hc.evaluate(res, NOW, max_lag=5, max_age=60, min_peers=5), [])

    def test_lagging_and_stale_and_peers(self):
        res = [hc.interpret("a", "local", "u", resp(900, NOW - 600, peers="0x2")),
               hc.interpret("ref", "reference", "u", resp(1000, NOW - 5, peers=None))]
        problems = hc.evaluate(res, NOW, max_lag=5, max_age=60, min_peers=5)
        text = "\n".join(problems)
        self.assertIn("落后最高高度 100 个块", text)
        self.assertIn("600 秒前", text)
        self.assertIn("对等节点只有 2 个", text)

    def test_reference_problems_not_reported_as_local(self):
        res = [hc.interpret("a", "local", "u", resp(1000, NOW - 5)),
               hc.Result(name="ref", role="reference", url="u", error="timeout")]
        problems = hc.evaluate(res, NOW, 5, 60, 5)
        self.assertEqual(problems, ["所有参考节点都不可用，高度差结果只在自建节点之间比较"])

    def test_chain_id_mismatch(self):
        res = [hc.interpret("a", "local", "u", resp(1000, NOW)),
               hc.interpret("ref", "reference", "u", resp(1000, NOW, chain="0xaa36a7"))]
        self.assertTrue(any("不在同一条链" in p for p in hc.evaluate(res, NOW, 5, 60, 5)))

    def test_local_down(self):
        res = [hc.Result(name="a", role="local", url="u", error="ConnectionRefusedError")]
        self.assertIn("a 不可用", hc.evaluate(res, NOW, 5, 60, 5)[0])

    def test_render_metrics(self):
        res = [hc.interpret("a", "local", "u", resp(990, NOW - 30)),
               hc.interpret("ref", "reference", "u", resp(1000, NOW, peers=None)),
               hc.Result(name="b", role="local", url="u", error="x")]
        text = hc.render_metrics(res, NOW)
        self.assertIn('eth_node_up{node="b",role="local"} 0', text)
        self.assertIn('eth_node_height_lag_blocks{node="a",role="local"} 10', text)
        self.assertIn('eth_node_block_age_seconds{node="a",role="local"} 30', text)
        self.assertNotIn('eth_node_peers{node="ref"', text)
        self.assertIn("# TYPE eth_node_block_height gauge", text)


if __name__ == "__main__":
    unittest.main()
