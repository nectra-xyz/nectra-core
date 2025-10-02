// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraBase} from "src/NectraBase.sol";

import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

import {IFlashLoanSimpleReceiver} from "src/interfaces/IFlashLoanSimpleReceiver.sol";

/// @title NectraFlash
/// @notice Provides flash loan functionality for NUSD tokens and native cBTC
/// @dev Implements flash minting and borrowing with callback execution
abstract contract NectraFlash is NectraBase {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    error OperationFailed();
    error FlashBorrowNotRepaid();

    /// @notice Emitted when a flash mint operation is executed
    /// @param initiator Address that initiated the flash mint
    /// @param to Address that received the minted tokens and the callback was triggered
    /// @param amount Amount of NUSD tokens minted
    /// @param fee Fee charged for the flash mint
    event FlashMint(address indexed initiator, address indexed to, uint256 amount, uint256 fee);

    /// @notice Emitted when a flash borrow operation is executed
    /// @param initiator Address that initiated the flash borrow
    /// @param to Address that received the borrowed cBTC and the callback was triggered
    /// @param amount Amount of cBTC borrowed
    /// @param fee Fee charged for the flash borrow
    event FlashBorrow(address indexed initiator, address indexed to, uint256 amount, uint256 fee);

    /// @notice Executes a flash mint with a callback
    /// @dev Mints NUSD tokens, executes callback, and burns tokens plus fee
    /// @param to Target contract that implements `executeOperation`
    /// @param amount Amount of NUSD to mint
    /// @param data Arbitrary data passed to callback
    function flashMint(address to, uint256 amount, bytes calldata data) external {
        require(amount > 0, InvalidAmount());

        _requireFlashMintUnlocked();
        _requireFlashBorrowUnlocked();

        _core().flashMintLock = true;

        uint256 fee = amount.mulWadUp(_systemConfig().FLASH_MINT_FEE);

        // mint
        NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).mint(to, amount);

        // call the callback
        require(
            IFlashLoanSimpleReceiver(to).executeOperation(
                _systemConfig().NUSD_TOKEN_ADDRESS, amount, fee, msg.sender, data
            ),
            OperationFailed()
        );

        // burn
        NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).burn(to, amount + fee);

        if (fee > 0) {
            NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).mint(_systemConfig().FEE_RECIPIENT_ADDRESS, fee);
        }

        _core().flashMintLock = false;

        emit FlashMint(msg.sender, to, amount, fee);
    }

    /// @notice Executes a flash borrow of native balance with callback
    /// @dev Lends cBTC, executes callback, and verifies repayment
    /// @param to Receiver contract that implements `executeOperation`
    /// @param amount Amount of cBTC to borrow
    /// @param data Arbitrary data passed to callback
    function flashBorrow(address to, uint256 amount, bytes calldata data) external {
        require(amount > 0 && amount <= address(this).balance, InvalidAmount());

        _requireFlashMintUnlocked();
        _requireFlashBorrowUnlocked();

        uint256 fee = amount.mulWadUp(_systemConfig().FLASH_BORROW_FEE);

        _core().flashBorrowLock = amount + fee;

        require(
            IFlashLoanSimpleReceiver(to).executeOperation{value: amount}(address(0), amount, fee, msg.sender, data),
            OperationFailed()
        );

        require(_core().flashBorrowLock == 0, FlashBorrowNotRepaid());

        _systemConfig().FEE_RECIPIENT_ADDRESS.safeTransferETH(fee);

        emit FlashBorrow(msg.sender, to, amount, fee);
    }

    /// @notice Repays an outstanding flash borrow
    /// @dev Accepts cBTC payment and clears the flash borrow lock
    function repayFlashBorrow() external payable {
        require(msg.value == _core().flashBorrowLock, InvalidAmount());

        _core().flashBorrowLock = 0;
    }
}
