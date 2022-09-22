// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.11;

import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import { Trust } from "@sense-finance/v1-utils/src/Trust.sol";
import { Errors } from "@sense-finance/v1-utils/src/libs/Errors.sol";

/// @title ExtractableReward
/// @notice Allows to extract rewards from the contract to the `rewardsRecepient`
abstract contract ExtractableReward is Trust {
    /// -----------------------------------------------------------------------
    /// Libraries usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// @notice Rewards recipient
    address public rewardsRecipient;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address _rewardsRecipient) Trust(msg.sender) {
        rewardsRecipient = _rewardsRecipient;
    }

    /// -----------------------------------------------------------------------
    /// Rewards extractor
    /// -----------------------------------------------------------------------

    function _isValid(address _token) internal virtual returns (bool);

    function extractToken(address token) external {
        // Check that token is neither eToken nor
        if (_isValid(token)) revert Errors.TokenNotSupported();
        ERC20 t = ERC20(token);
        t.safeTransfer(rewardsRecipient, t.balanceOf(address(this)));
        emit RewardsClaimed(token, rewardsRecipient);
    }

    /// -----------------------------------------------------------------------
    /// Admin functions
    /// -----------------------------------------------------------------------
    function setRewardsRecipient(address recipient) external requiresTrust {
        rewardsRecipient = recipient;
        emit RewardsRecipientChanged(rewardsRecipient);
    }

    /// -----------------------------------------------------------------------
    /// Logs
    /// -----------------------------------------------------------------------
    event RewardsRecipientChanged(address indexed recipient);
    event RewardsClaimed(address indexed token, address indexed recipient);
}