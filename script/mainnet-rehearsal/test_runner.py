"""Offline regression tests for safety and evidence gates; no chain or credentials needed."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from web3 import Web3
from web3.datastructures import AttributeDict

from common import Rehearsal, local_url
from rehearse import ATTEMPT_ARTIFACTS
from scenarios import Campaign, allocation


class RunnerSafetyTest(unittest.TestCase):
    def test_resume_archives_same_block_submission_journal(self):
        self.assertIn("same-block-submissions.jsonl", ATTEMPT_ARTIFACTS)

    def test_independent_split_model_covers_extremes_and_per_purchase_floors(self):
        cfg = ["asset", 1, 10, 60, 3, 10, 0, 2000, 0]
        self.assertEqual(allocation(cfg, [10], 8000), (10, 0, 2, 8, 0, 0))
        cfg[6] = 10000
        self.assertEqual(allocation(cfg, [10], 8000), (10, 10, 0, 0, 0, 0))
        cfg[6], cfg[8] = 5000, 1
        self.assertEqual(allocation(cfg, [1, 1, 1], 5000), (3, 1, 0, 0, 1, 1))

    def test_deployment_receipts_survive_address_reuse_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            r, _ = self.transaction_fixture(directory, 1)
            r.deployed = []
            r.artifact = Mock(return_value={"abi": [], "bytecode": {"object": "0x6000"},
                                            "deployedBytecode": {"object": "0x6000"}})
            r.w3.eth.get_code.return_value = bytes.fromhex("6000")
            receipt = AttributeDict({"contractAddress": "0x" + "44" * 20,
                "status": 1, "transactionHash": bytes.fromhex("55" * 32)})
            r.w3.eth.wait_for_transaction_receipt.return_value = receipt
            r.deploy("First")
            r.deploy("Second")
            self.assertEqual([d["name"] for d in r.deployed], ["First", "Second"])
            r.w3.eth.wait_for_transaction_receipt.return_value = AttributeDict({
                "contractAddress": None, "status": 0, "transactionHash": bytes.fromhex("66" * 32)})
            with self.assertRaisesRegex(AssertionError, "Deployment failed"):
                r.deploy("Failed")
            self.assertEqual(len(r.deployed), 3)

    def transaction_fixture(self, directory, status):
        r = Rehearsal.__new__(Rehearsal)
        r.run = Path(directory)
        r.guard = Mock()
        r.owner = "0x" + "11" * 20
        r.scenario = "unit"
        r.counter = 0
        r.lottery = None
        r.w3 = Mock()
        r.w3.eth.gas_price = 100_000_000
        r.w3.eth.wait_for_transaction_receipt.return_value = AttributeDict({
            "transactionHash": bytes.fromhex("22" * 32), "status": status,
            "blockNumber": 10, "transactionIndex": 0})
        fn = Mock()
        fn.address = "0x" + "33" * 20
        fn.abi = {"type": "function", "name": "mutate", "inputs": []}
        fn._encode_transaction_data.return_value = "0x12345678"
        return r, fn

    def test_mined_failure_never_counts_as_success_and_receipt_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            r, fn = self.transaction_fixture(directory, 0)
            with self.assertRaisesRegex(AssertionError, "Unexpected mined revert"):
                r.tx(fn)
            self.assertTrue((Path(directory) / "receipts/00001.json").exists())

    def test_same_block_send_failure_restores_automining(self):
        with tempfile.TemporaryDirectory() as directory:
            r, fn = self.transaction_fixture(directory, 1)
            r.w3.eth.get_transaction_count.return_value = 0
            r.w3.eth.send_transaction.side_effect = RuntimeError("send failed")
            r.rpc = Mock(return_value=True)
            with self.assertRaisesRegex(RuntimeError, "send failed"):
                r.same_block([{"fn": fn}])
            self.assertEqual(r.rpc.call_args_list[0].args, ("evm_setAutomine", [False]))
            self.assertEqual(r.rpc.call_args_list[-1].args, ("evm_setAutomine", [True]))

    def test_same_block_second_send_failure_retains_first_submission_and_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            r, fn = self.transaction_fixture(directory, 1)
            first_hash = bytes.fromhex("44" * 32)
            r.w3.eth.get_transaction_count.return_value = 0
            r.w3.eth.send_transaction.side_effect = [first_hash, RuntimeError("second send failed")]
            r.rpc = Mock(return_value=True)
            with self.assertRaisesRegex(RuntimeError, "second send failed"):
                r.same_block([{"fn": fn}, {"fn": fn}])
            receipt = Path(directory) / "receipts/00001.json"
            submissions = Path(directory) / "same-block-submissions.jsonl"
            self.assertTrue(receipt.exists())
            self.assertIn("0x" + first_hash.hex(), submissions.read_text())
            self.assertEqual(r.rpc.call_args_list[-1].args, ("evm_setAutomine", [True]))

    def test_same_block_early_outcome_failure_retains_every_receipt_and_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            r, fn = self.transaction_fixture(directory, 1)
            hashes = [bytes.fromhex("44" * 32), bytes.fromhex("55" * 32)]
            receipts = [
                AttributeDict({"transactionHash": hashes[0], "status": 0,
                               "blockNumber": 10, "transactionIndex": 0}),
                AttributeDict({"transactionHash": hashes[1], "status": 1,
                               "blockNumber": 10, "transactionIndex": 1}),
            ]
            r.w3.eth.get_transaction_count.return_value = 0
            r.w3.eth.send_transaction.side_effect = hashes
            r.w3.eth.wait_for_transaction_receipt.side_effect = receipts
            r.rpc = Mock(side_effect=lambda method, _: {"output": "0xdeadbeef"}
                         if method == "debug_traceTransaction" else True)
            with self.assertRaisesRegex(AssertionError, "Unexpected same-block revert"):
                r.same_block([{"fn": fn}, {"fn": fn}])
            first = json.loads((Path(directory) / "receipts/00001.json").read_text())
            self.assertEqual(first["trace"]["output"], "0xdeadbeef")
            self.assertTrue((Path(directory) / "receipts/00002.json").exists())

    def test_expected_revert_requires_correct_error_and_financial_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            r, fn = self.transaction_fixture(directory, 0)
            r.rpc = Mock(return_value={"output": "0xdeadbeef"})
            with self.assertRaisesRegex(AssertionError, "Expected ZeroAmount"):
                r.tx(fn, error="ZeroAmount()")
            r.rpc.return_value = {"output": "0x" + Web3.keccak(text="ZeroAmount()")[:4].hex()}
            with self.assertRaisesRegex(AssertionError, "Failed rollback"):
                r.tx(fn, error="ZeroAmount()", check=Mock(side_effect=[{"balance": 10}, {"balance": 9}]))

    def test_only_explicit_loopback_endpoints_are_accepted(self):
        self.assertEqual(local_url("http://127.0.0.1:8855"), 8855)
        for url in ["https://127.0.0.1:8855", "http://localhost:8855", "http://example.org:8855",
                    "http://127.0.0.1", "http://user:pass@127.0.0.1:8855", "http://127.0.0.1:8855/path",
                    "http://127.0.0.1:8855?upstream=remote", "http://127.0.0.1:8855#remote"]:
            with self.subTest(url=url), self.assertRaises(AssertionError):
                local_url(url)

    def test_guard_rejects_wrong_chain_non_anvil_and_replaced_instance(self):
        r = Rehearsal.__new__(Rehearsal)
        r.environment = {"instanceId": "owned", "forkBlock": 100, "forkHash": "0xabc"}
        r.w3 = Mock()
        r.w3.eth.chain_id = 4663
        r.w3.client_version = "anvil/test"
        meta = {"instanceId": "owned", "forkedNetwork": {"forkBlockNumber": 100, "forkBlockHash": "0xabc"}}
        r.rpc = Mock(return_value=meta)
        r.guard()
        for change in ["chain", "client", "instance", "block", "hash"]:
            with self.subTest(change=change):
                r.w3.eth.chain_id = 1 if change == "chain" else 4663
                r.w3.client_version = "geth" if change == "client" else "anvil/test"
                r.rpc.return_value = {"instanceId": "foreign" if change == "instance" else "owned",
                    "forkedNetwork": {"forkBlockNumber": 101 if change == "block" else 100,
                                      "forkBlockHash": "0xdef" if change == "hash" else "0xabc"}}
                with self.assertRaises(AssertionError):
                    r.guard()

    def test_route_inventory_alone_cannot_satisfy_behavioral_coverage(self):
        r = Campaign.__new__(Campaign)
        r.installed = {"12345678": {"signature": "withdraw()", "name": "Facet", "facet": "0x123"}}
        r.coverage = {"withdraw()": {"view": [], "success": [], "revert": [{"transactionHash": "0xfail"}]}}
        r.lottery = Mock()
        r.lottery.abi = [{"type": "function", "name": "withdraw", "inputs": [], "outputs": [], "stateMutability": "nonpayable"}]
        with tempfile.TemporaryDirectory() as directory:
            r.run = Path(directory)
            with self.assertRaisesRegex(AssertionError, "Missing direct selector coverage"):
                r.coverage_gate()

    def test_coverage_exceptions_require_actual_evidence(self):
        for name, types in [("protocolMoveFiddy", ["address", "address", "uint256"]),
                            ("initializeFiddy", ["address"] * 4)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                r = Campaign.__new__(Campaign)
                r.run = Path(directory)
                signature = name + "(" + ",".join(types) + ")"
                r.installed = {"12345678": {"signature": signature}}
                r.coverage = {}
                r.lottery = Mock()
                r.lottery.abi = [{"type": "function", "name": name, "stateMutability": "nonpayable",
                    "inputs": [{"name": "arg" + str(i), "type": t} for i, t in enumerate(types)], "outputs": []}]
                with self.assertRaisesRegex(AssertionError, "Missing direct selector coverage"):
                    r.coverage_gate()


if __name__ == "__main__":
    unittest.main()
