// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {Ownable} from "../src/Ownable.sol";

contract ModelRegistryTest is Test {
    ModelRegistry internal registry;

    address internal authority;

    uint8 internal constant TIER_LITE = 0x01;
    uint8 internal constant TIER_STANDARD = 0x02;
    uint8 internal constant TIER_PRO = 0x04;
    uint8 internal constant TIER_MAX = 0x08;

    event ModelRegistered(
        bytes32 indexed modelId,
        uint8 requiredTier,
        address indexed registeredBy
    );
    event ModelStatusUpdated(bytes32 indexed modelId, bool active);
    event ModelTierUpdated(bytes32 indexed modelId, uint8 oldTier, uint8 newTier);
    event ModelDescriptionUpdated(bytes32 indexed modelId, string description);

    function setUp() public {
        authority = address(this);
        registry = new ModelRegistry();
    }

    struct Entry {
        string name;
        string description;
        uint8 requiredTier;
        bool active;
        uint64 registeredAt;
        address registeredBy;
    }

    function _model(bytes32 modelId) internal view returns (Entry memory e) {
        (
            e.name,
            e.description,
            e.requiredTier,
            e.active,
            e.registeredAt,
            e.registeredBy
        ) = registry.models(modelId);
    }

    function _repeat(bytes1 char, uint256 len) internal pure returns (string memory) {
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = char;
        }
        return string(out);
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function test_initializesTheRegistry() public view {
        assertEq(registry.modelCount(), 0);
        assertEq(registry.owner(), authority);
    }

    // ---------------------------------------------------------------------
    // registerModel
    // ---------------------------------------------------------------------

    function test_registersNewModel() public {
        bytes32 modelId = keccak256("model-llama3");

        vm.expectEmit(true, true, false, true);
        emit ModelRegistered(modelId, TIER_STANDARD | TIER_PRO, authority);

        registry.registerModel(
            modelId,
            "Llama-3-8B-Instruct",
            "Meta Llama 3 8B instruction-tuned",
            TIER_STANDARD | TIER_PRO
        );

        Entry memory model = _model(modelId);
        assertTrue(model.active);
        assertEq(model.requiredTier, TIER_STANDARD | TIER_PRO);
        assertEq(model.registeredBy, authority);
        assertEq(model.name, "Llama-3-8B-Instruct");
        assertEq(model.description, "Meta Llama 3 8B instruction-tuned");
        assertEq(model.registeredAt, uint64(block.timestamp));

        assertEq(registry.modelCount(), 1);
    }

    function test_rejectsZeroTierMask() public {
        bytes32 modelId = keccak256("model-bad");

        vm.expectRevert(ModelRegistry.NoTiersDeclared.selector);
        registry.registerModel(modelId, "bad-model", "desc", 0);
    }

    function test_rejectsTierMaskWithOutOfRangeBits() public {
        bytes32 modelId = keccak256("model-bad-2");

        // Bit 5 is outside the four valid tiers.
        vm.expectRevert(ModelRegistry.InvalidTierMask.selector);
        registry.registerModel(modelId, "bad-model-2", "desc", 0x10);
    }

    function test_rejectsNameOverMaximumLength() public {
        bytes32 modelId = keccak256("model-long-name");
        string memory longName = _repeat("a", registry.NAME_MAX() + 1);

        vm.expectRevert(ModelRegistry.NameTooLong.selector);
        registry.registerModel(modelId, longName, "desc", TIER_LITE);
    }

    function test_rejectsDescriptionOverMaximumLength() public {
        bytes32 modelId = keccak256("model-long-desc");
        string memory longDesc = _repeat("d", registry.DESCRIPTION_MAX() + 1);

        vm.expectRevert(ModelRegistry.DescriptionTooLong.selector);
        registry.registerModel(modelId, "ok-name", longDesc, TIER_LITE);
    }

    function test_rejectsDuplicateModelId() public {
        bytes32 modelId = keccak256("model-dup");
        registry.registerModel(modelId, "first", "first entry", TIER_LITE);

        vm.expectRevert(ModelRegistry.ModelAlreadyRegistered.selector);
        registry.registerModel(modelId, "second", "second entry", TIER_MAX);
    }

    // ---------------------------------------------------------------------
    // setModelActive
    // ---------------------------------------------------------------------

    function test_deactivatesModel() public {
        bytes32 modelId = keccak256("model-gptj");
        registry.registerModel(
            modelId,
            "GPT-J-6B",
            "EleutherAI GPT-J 6B",
            TIER_LITE | TIER_STANDARD
        );

        vm.expectEmit(true, false, false, true);
        emit ModelStatusUpdated(modelId, false);

        registry.setModelActive(modelId, false);

        Entry memory model = _model(modelId);
        assertFalse(model.active);
    }

    function test_reactivatesModel() public {
        bytes32 modelId = keccak256("model-reactivate");
        registry.registerModel(modelId, "cycle-model", "toggled", TIER_LITE);

        registry.setModelActive(modelId, false);
        registry.setModelActive(modelId, true);

        Entry memory model = _model(modelId);
        assertTrue(model.active);
    }

    function test_setModelActive_rejectsUnknownModel() public {
        vm.expectRevert(ModelRegistry.ModelNotFound.selector);
        registry.setModelActive(keccak256("model-missing"), false);
    }

    // ---------------------------------------------------------------------
    // updateRequiredTier
    // ---------------------------------------------------------------------

    function test_updatesModelRequiredTier() public {
        bytes32 modelId = keccak256("model-mistral");
        registry.registerModel(modelId, "Mistral-7B-v0.3", "Mistral 7B v0.3", TIER_MAX);

        // Quantised version ships — now runs on Pro or above.
        vm.expectEmit(true, false, false, true);
        emit ModelTierUpdated(modelId, TIER_MAX, TIER_PRO | TIER_MAX);

        registry.updateRequiredTier(modelId, TIER_PRO | TIER_MAX);

        Entry memory model = _model(modelId);
        assertEq(model.requiredTier, TIER_PRO | TIER_MAX);
    }

    function test_updateRequiredTier_rejectsZeroMask() public {
        bytes32 modelId = keccak256("model-update-bad");
        registry.registerModel(modelId, "update-bad", "desc", TIER_MAX);

        vm.expectRevert(ModelRegistry.NoTiersDeclared.selector);
        registry.updateRequiredTier(modelId, 0);
    }

    function test_updateRequiredTier_rejectsOutOfRangeMask() public {
        bytes32 modelId = keccak256("model-update-bad-2");
        registry.registerModel(modelId, "update-bad-2", "desc", TIER_MAX);

        vm.expectRevert(ModelRegistry.InvalidTierMask.selector);
        registry.updateRequiredTier(modelId, 0x10);
    }

    function test_updateRequiredTier_rejectsUnknownModel() public {
        vm.expectRevert(ModelRegistry.ModelNotFound.selector);
        registry.updateRequiredTier(keccak256("model-missing-2"), TIER_LITE);
    }

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    function test_rejectsModelOperationsFromNonAuthority() public {
        bytes32 modelId = keccak256("model-qwen");
        registry.registerModel(modelId, "Qwen-72B", "Alibaba Qwen 72B", TIER_MAX);

        address imposter = makeAddr("imposter");

        vm.prank(imposter);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setModelActive(modelId, false);

        vm.prank(imposter);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.updateRequiredTier(modelId, TIER_PRO);

        vm.prank(imposter);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.registerModel(keccak256("model-imposter"), "sneaky", "nope", TIER_LITE);
    }

    function test_updatesDescription() public {
        bytes32 modelId = keccak256("model-describe");
        registry.registerModel(modelId, "describe-model", "old text", TIER_LITE);

        vm.expectEmit(true, false, false, true);
        emit ModelDescriptionUpdated(modelId, "new text");

        registry.updateDescription(modelId, "new text");

        assertEq(_model(modelId).description, "new text");
    }

    function test_rejectsDescriptionUpdateForUnknownModel() public {
        vm.expectRevert(ModelRegistry.ModelNotFound.selector);
        registry.updateDescription(keccak256("model-missing"), "anything");
    }

    function test_rejectsDescriptionUpdateOverMaximumLength() public {
        bytes32 modelId = keccak256("model-long-update");
        registry.registerModel(modelId, "long-model", "short", TIER_LITE);
        string memory tooLong = _repeat("a", registry.DESCRIPTION_MAX() + 1);

        vm.expectRevert(ModelRegistry.DescriptionTooLong.selector);
        registry.updateDescription(modelId, tooLong);
    }
}
