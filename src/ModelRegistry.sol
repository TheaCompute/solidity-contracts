// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "./Ownable.sol";

/// @title ModelRegistry
/// @notice Owner-curated catalog of AI models available on the TheaCompute
///         network. Each model declares the minimum hardware tiers workers
///         must support to serve it.
contract ModelRegistry is Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Tier bit flags matching the worker registry and job escrow
    ///         conventions.
    uint8 public constant TIER_LITE = 0x01;
    uint8 public constant TIER_STANDARD = 0x02;
    uint8 public constant TIER_PRO = 0x04;
    uint8 public constant TIER_MAX = 0x08;

    uint256 public constant NAME_MAX = 64;
    uint256 public constant DESCRIPTION_MAX = 128;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct ModelEntry {
        string name;
        string description;
        uint8 requiredTier;
        bool active;
        uint64 registeredAt;
        address registeredBy;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 public modelCount;

    mapping(bytes32 => ModelEntry) public models;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ModelRegistered(
        bytes32 indexed modelId,
        uint8 requiredTier,
        address indexed registeredBy
    );
    event ModelStatusUpdated(bytes32 indexed modelId, bool active);
    event ModelTierUpdated(bytes32 indexed modelId, uint8 oldTier, uint8 newTier);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice At least one tier must be declared in the requiredTier mask.
    error NoTiersDeclared();
    /// @notice Tier mask has bits set beyond the four valid tiers.
    error InvalidTierMask();
    /// @notice No model is registered under this ID.
    error ModelNotFound();
    /// @notice A model is already registered under this ID.
    error ModelAlreadyRegistered();
    /// @notice Model name exceeds NAME_MAX bytes.
    error NameTooLong();
    /// @notice Model description exceeds DESCRIPTION_MAX bytes.
    error DescriptionTooLong();

    // ---------------------------------------------------------------------
    // Curation
    // ---------------------------------------------------------------------

    /// @notice The curating authority registers a new model in the catalog.
    ///         The requiredTier bitmask determines the minimum hardware tier
    ///         workers must declare to serve this model
    ///         (e.g. TIER_PRO | TIER_MAX = 0x0C).
    function registerModel(
        bytes32 modelId,
        string calldata name,
        string calldata description,
        uint8 requiredTier
    ) external onlyOwner {
        if (requiredTier == 0) revert NoTiersDeclared();
        if (requiredTier > 0x0F) revert InvalidTierMask();
        if (bytes(name).length > NAME_MAX) revert NameTooLong();
        if (bytes(description).length > DESCRIPTION_MAX) revert DescriptionTooLong();
        if (models[modelId].registeredBy != address(0)) revert ModelAlreadyRegistered();

        models[modelId] = ModelEntry({
            name: name,
            description: description,
            requiredTier: requiredTier,
            active: true,
            registeredAt: uint64(block.timestamp),
            registeredBy: msg.sender
        });

        modelCount += 1;

        emit ModelRegistered(modelId, requiredTier, msg.sender);
    }

    /// @notice Toggle a model active or inactive. Inactive models should not
    ///         be dispatched to workers even if they declare support for the
    ///         tier.
    function setModelActive(bytes32 modelId, bool active) external onlyOwner {
        ModelEntry storage model = models[modelId];
        if (model.registeredBy == address(0)) revert ModelNotFound();
        model.active = active;

        emit ModelStatusUpdated(modelId, active);
    }

    /// @notice Update the minimum hardware tier required to serve a model,
    ///         e.g. after a quantised variant ships that can run on lower-end
    ///         hardware.
    function updateRequiredTier(bytes32 modelId, uint8 requiredTier) external onlyOwner {
        if (requiredTier == 0) revert NoTiersDeclared();
        if (requiredTier > 0x0F) revert InvalidTierMask();

        ModelEntry storage model = models[modelId];
        if (model.registeredBy == address(0)) revert ModelNotFound();
        uint8 oldTier = model.requiredTier;
        model.requiredTier = requiredTier;

        emit ModelTierUpdated(modelId, oldTier, requiredTier);
    }
}
