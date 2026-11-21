"""Offline checks for the read-only deployment preflight."""

import unittest

from web3 import Web3
from web3.providers.base import BaseProvider

from preflight import check, validate_manifest


NAMES = (
    "registry", "statics", "positionNFT", "router", "operatorCollection",
    "activationRegistry", "operatorVault", "authority",
)
CODE = bytes.fromhex("60006000")
CODE_HASH = "0x" + Web3.keccak(CODE).hex().removeprefix("0x")


def manifest():
    return {
        "chainId": 4663,
        "contracts": {
            name: {"address": "0x" + f"{index:040x}", "runtimeCodeHash": CODE_HASH}
            for index, name in enumerate(NAMES, 1)
        },
        "rewardAssets": ["statics"],
        "minimumAuthorityDelaySeconds": 86400,
    }


class FakeEth:
    chain_id = 4663
    block_number = 123

    def __init__(self, config):
        self.config = config
        self.code = CODE
        self.interface_supported = True
        self.router_ready = True
        self.delay = 86400
        self.binding_override = None
        self.read_blocks = []
        self.state_refs = []
        self.block_hashes = [bytes.fromhex("aa" * 32)]
        self.block_hash_reads = 0
        self.supports_hash_refs = True

    def get_block(self, block):
        self.read_blocks.append(block)
        index = min(self.block_hash_reads, len(self.block_hashes) - 1)
        self.block_hash_reads += 1
        return {"hash": self.block_hashes[index]}

    def get_code(self, address, block_identifier=None):
        self.state_refs.append(block_identifier)
        if not self.supports_hash_refs:
            raise RuntimeError("EIP-1898 unsupported")
        return self.code

    def call(self, tx, block_identifier=None):
        self.state_refs.append(block_identifier)
        if not self.supports_hash_refs:
            raise RuntimeError("EIP-1898 unsupported")
        selector = bytes(tx["data"][:4])
        signature = lambda text: Web3.keccak(text=text)[:4]
        if selector == signature("supportsInterface(bytes4)"):
            assert bytes(tx["data"][4:8]).hex() == "2795ac62"
            value = int(self.interface_supported)
        elif selector == signature("getMinDelay()"):
            value = self.delay
        elif selector in (signature("bootstrapFinalized()"),
                          signature("totalEffectiveWeight()"),
                          signature("isRewardAsset(address)"),
                          signature("rewardAssetEnabled(address)")):
            value = int(self.router_ready)
        else:
            for name in ("operatorCollection", "activationRegistry", "operatorVault"):
                if selector == signature(f"{name}()"):
                    value = (self.binding_override if self.binding_override is not None
                             else int(self.config["contracts"][name]["address"], 16))
                    break
            else:
                raise AssertionError("unexpected selector")
        return value.to_bytes(32, "big")


class FakeWeb3:
    def __init__(self, config):
        self.eth = FakeEth(config)


class RecordingProvider(BaseProvider):
    def __init__(self):
        super().__init__()
        self.requests = []

    def make_request(self, method, params):
        self.requests.append((method, params))
        result = "0x1" if method == "eth_chainId" else "0x"
        return {"jsonrpc": "2.0", "id": 1, "result": result}


class DeploymentPreflightTest(unittest.TestCase):
    def test_web3_sends_eip_1898_block_hash_for_code_and_calls(self):
        provider = RecordingProvider()
        w3 = Web3(provider)
        address = Web3.to_checksum_address("0x" + "11" * 20)
        ref = {"blockHash": "0x" + "aa" * 32, "requireCanonical": True}
        w3.eth.get_code(address, block_identifier=ref)
        w3.eth.call({"to": address, "data": "0x"}, block_identifier=ref,
                    ccip_read_enabled=False)
        state_reads = [params for method, params in provider.requests
                       if method in ("eth_getCode", "eth_call")]
        self.assertEqual([params[1] for params in state_reads], [ref, ref])

    def test_valid_candidate_reads_one_block_without_transactions(self):
        config = validate_manifest(manifest())
        w3 = FakeWeb3(config)
        self.assertEqual(check(config, w3), [])
        self.assertEqual(set(w3.eth.read_blocks), {123})
        self.assertEqual(w3.eth.block_hash_reads, 2)
        self.assertTrue(w3.eth.state_refs)
        self.assertTrue(all(ref == {"blockHash": "0x" + "aa" * 32,
                                    "requireCanonical": True}
                            for ref in w3.eth.state_refs))

    def test_replaced_block_height_fails_after_reads(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.block_hashes = [bytes.fromhex("aa" * 32), bytes.fromhex("bb" * 32)]
        self.assertEqual(check(config, w3),
                         ["block hash: selected height changed during preflight"])
        self.assertEqual(set(w3.eth.read_blocks), {123})
        self.assertEqual(w3.eth.block_hash_reads, 2)

    def test_endpoint_without_hash_pinned_reads_cannot_pass(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.supports_hash_refs = False
        failures = check(config, w3)
        self.assertIn("registry: code read failed", failures)
        self.assertIn("authority: getMinDelay() read failed", failures)
        self.assertEqual(set(w3.eth.read_blocks), {123})

    def test_zero_operator_assets_skip_router_readiness(self):
        config = manifest()
        config["rewardAssets"] = []
        validate_manifest(config)
        w3 = FakeWeb3(config)
        w3.eth.router_ready = False
        self.assertEqual(check(config, w3), [])

    def test_unavailable_block_hash_fails_closed(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.block_hashes = [b""]
        self.assertEqual(check(config, w3), ["block hash: initial RPC read failed"])
        w3.eth.block_hashes = [bytes.fromhex("aa" * 32), b""]
        w3.eth.block_hash_reads = 0
        self.assertEqual(check(config, w3), ["block hash: final RPC read failed"])

    def test_wrong_chain_stops_before_other_reads(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.chain_id = 1
        self.assertEqual(check(config, w3), ["chain ID: expected 4663, got 1"])
        self.assertEqual(w3.eth.read_blocks, [])

    def test_changed_runtime_fails(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.code = bytes.fromhex("6001")
        failures = check(config, w3)
        self.assertTrue(any("runtime code hash mismatch" in item for item in failures))

    def test_unsupported_statics_interface_or_inactive_router_fail(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.interface_supported = False
        w3.eth.router_ready = False
        failures = check(config, w3)
        self.assertTrue(any("interface unsupported" in item for item in failures))
        self.assertTrue(any("bootstrap" in item for item in failures))
        self.assertTrue(any("statics not registered" in item for item in failures))

    def test_insufficient_authority_delay_fails(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.delay = 0
        self.assertIn("authority: timelock delay below required minimum", check(config, w3))

    def test_router_binding_mismatch_fails(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.binding_override = 999
        failures = check(config, w3)
        self.assertTrue(any("binding mismatch" in item for item in failures))

    def test_missing_code_and_unreadable_block_fail_closed(self):
        config = manifest()
        w3 = FakeWeb3(config)
        w3.eth.code = b""
        self.assertIn("registry: no contract code", check(config, w3))

        class NoBlock(FakeEth):
            @property
            def block_number(self):
                raise RuntimeError("RPC unavailable")

        w3.eth = NoBlock(config)
        self.assertEqual(check(config, w3), ["block number: RPC read failed"])

    def test_manifest_rejects_missing_expectations(self):
        config = manifest()
        del config["contracts"]["registry"]
        with self.assertRaisesRegex(ValueError, "contracts must contain"):
            validate_manifest(config)
        config = manifest()
        config["minimumAuthorityDelaySeconds"] = 0
        with self.assertRaisesRegex(ValueError, "minimumAuthorityDelaySeconds"):
            validate_manifest(config)
        config = manifest()
        config["rewardAssets"] = ["missing"]
        with self.assertRaisesRegex(ValueError, "rewardAssets"):
            validate_manifest(config)


if __name__ == "__main__":
    unittest.main()
