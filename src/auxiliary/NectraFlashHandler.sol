// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NectraLib} from "src/NectraLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

import {IERC20} from "src/interfaces/IERC20.sol";
import {INectra} from "src/interfaces/INectra.sol";
import {INectraNFT} from "src/interfaces/INectraNFT.sol";
import {INectraExternal} from "src/interfaces/INectraExternal.sol";
import {ISatsumaHandler} from "src/interfaces/Satsuma/ISatsumaHandler.sol";
import {IOracleAggregator} from "src/interfaces/IOracleAggregator.sol";
import {IFlashLoanSimpleReceiver} from "src/interfaces/IFlashLoanSimpleReceiver.sol";

contract NectraFlashHandler is IFlashLoanSimpleReceiver {
    using SafeCastLib for int256;
    using SafeCastLib for uint256;
    using NectraMathLib for uint256;
    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    uint256 constant UNIT = 1 ether;

    error InvalidAsset(address asset);
    error InvalidPositionId(uint256 tokenId);
    error InvalidCBTCPrice(uint256 cBTCPrice, bool isStale);
    error InvalidAmount(uint256 amount, uint256 expectedAmount);
    error MaxDebtExceeded(uint256 swapAmountOut, uint256 maxDebt);
    error UnauthorizedCaller(address caller, address allowedCaller);
    error DesiredCollateralTooLow(uint256 desiredCollateral, uint256 msgValue);
    error IssuanceRatioExceeded(uint256 actualIssuanceRatio, uint256 maxIssuanceRatio);
    error InsufficientCollateralOut(uint256 actualCollateralOut, uint256 minCollateralOut);
    error InsufficientCollateralForSwap(uint256 availableCollateral, uint256 requiredCollateral);

    uint256 private receiveAmountLock;

    IERC20 internal immutable nUSD;
    INectra internal immutable nectra;
    INectraNFT internal immutable nectraNFT;
    INectraExternal internal immutable nectraExternal;
    IOracleAggregator internal immutable oracleAggregator;
    ISatsumaHandler internal immutable satsumaHandler;

    constructor(
        address _nUSD,
        address _nectra,
        address _nectraNFT,
        address _nectraExternal,
        address _oracleAggregator,
        address payable _satsumaHandler
    ) {
        nUSD = IERC20(_nUSD);
        nectra = INectra(_nectra);
        nectraNFT = INectraNFT(_nectraNFT);
        nectraExternal = INectraExternal(_nectraExternal);
        oracleAggregator = IOracleAggregator(_oracleAggregator);
        satsumaHandler = ISatsumaHandler(_satsumaHandler);
    }

    /*
     * External View Functions
     */

    /// @notice Get quote for closing a position
    /// @param tokenId The position to close
    /// @param limitSqrtPrice Price limit for the swap
    /// @return collateralOut Expected collateral output after closing
    /// @return collateralToSwap Amount of collateral that will be swapped to repay the loan and flash mint fee
    /// @return positionCollateral Amount of collateral in the position
    function quoteClosePosition(uint256 tokenId, uint160 limitSqrtPrice)
        external
        returns (uint256 collateralOut, uint256 collateralToSwap, uint256 positionCollateral)
    {
        // Caller does not need to be authorized to quote closing a position
        _requirePositionExists(tokenId);

        uint256 positionDebt;
        (positionCollateral, positionDebt,) = nectraExternal.getPosition(tokenId);
        require(positionDebt > 0, InvalidAmount(positionDebt, 0));
        require(positionCollateral > 0, InvalidAmount(positionCollateral, 0));

        uint256 flashMintFee = positionDebt.mulWadUp(nectraExternal.FLASH_MINT_FEE());
        uint256 totalRepayment = positionDebt + flashMintFee;

        (collateralToSwap,) = satsumaHandler.getCBTCToNUSDExactOutputQuote(totalRepayment, limitSqrtPrice);
        collateralOut = positionCollateral - collateralToSwap;
    }

    /*
     * External Functions
     */

    /// @notice Create or increase the exposure of a leveraged position
    /// @param tokenId The position to modify
    /// @param desiredCollateral The desired final collateral in the position
    /// @param desiredInterestRate The desired interest rate
    /// @param maxDebt The maximum debt allowed in the position
    /// @param recipient The address to receive the position NFT when creating a new position
    /// @return tokenId The token ID of the position
    /// @dev If tokenId is 0, a new position is created. If tokenId is not 0, the position is modified.
    function increasePositionExposure(
        uint256 tokenId,
        uint256 desiredCollateral,
        uint256 desiredInterestRate,
        uint256 maxDebt,
        address recipient
    ) external payable returns (uint256) {
        uint256 existingPositionCollateral = 0;

        if (tokenId > 0) {
            _requirePositionExists(tokenId);

            uint256 permissionBitmask = 1 << uint256(INectraNFT.Permission.Deposit);
            permissionBitmask |= 1 << uint256(INectraNFT.Permission.Borrow);

            uint256 positionInterestRate;
            (existingPositionCollateral,, positionInterestRate) = nectraExternal.getPosition(tokenId);

            if (positionInterestRate != desiredInterestRate) {
                permissionBitmask |= 1 << uint256(INectraNFT.Permission.AdjustInterest);
            }

            _requireCallerAuthorized(tokenId, msg.sender, permissionBitmask);
        }

        require(
            desiredCollateral > msg.value + existingPositionCollateral,
            DesiredCollateralTooLow(desiredCollateral, msg.value + existingPositionCollateral)
        );

        uint256 minTargetCratio = getCBTCPrice().mulWad(desiredCollateral).divWad(maxDebt);
        require(
            minTargetCratio >= nectraExternal.ISSUANCE_RATIO(),
            IssuanceRatioExceeded(minTargetCratio, nectraExternal.ISSUANCE_RATIO())
        );

        bytes memory params = abi.encode(tokenId, desiredCollateral, desiredInterestRate, maxDebt);
        uint256 collateralToBorrow = desiredCollateral - msg.value - existingPositionCollateral;

        nectra.flashBorrow(address(this), collateralToBorrow, params);

        if (tokenId == 0) {
            tokenId = nectraNFT.totalSupply();
            // Send position NFT to recipient
            nectraNFT.transferFrom(address(this), recipient, tokenId);
        }

        return tokenId;
    }

    /// @notice Close a leveraged position by flash minting nUSD to repay debt and withdraw collateral
    /// @param tokenId The position to close
    /// @param minCollateralOut Minimum collateral to receive after closing (slippage protection)
    /// @param recipient Address to receive the withdrawn collateral
    /// @return collateralOut Amount of collateral sent to recipient
    function flashClosePosition(uint256 tokenId, uint256 minCollateralOut, address recipient)
        external
        returns (uint256 collateralOut)
    {
        _requirePositionExists(tokenId);

        uint256 permissionBitmask = 1 << uint256(INectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(INectraNFT.Permission.Withdraw);
        _requireCallerAuthorized(tokenId, msg.sender, permissionBitmask);

        (uint256 positionCollateral, uint256 positionDebt, uint256 positionInterestRate) =
            nectraExternal.getPosition(tokenId);

        require(positionDebt > 0, InvalidAmount(positionDebt, 0));
        require(positionCollateral > 0, InvalidAmount(positionCollateral, 0));

        // Encode parameters for the callback
        bytes memory params = abi.encode(tokenId, positionDebt, positionCollateral, positionInterestRate);

        // Initiate flash mint
        nectra.flashMint(address(this), positionDebt, params);

        // Send remaining collateral to recipient
        uint256 remainingCollateral = address(this).balance;
        require(
            remainingCollateral >= minCollateralOut, InsufficientCollateralOut(remainingCollateral, minCollateralOut)
        );

        if (remainingCollateral > 0) {
            recipient.safeTransferETH(remainingCollateral);
        }

        return remainingCollateral;
    }

    /// @notice Callback function for flashBorrow
    /// @param asset The asset being borrowed
    /// @param amount The amount of the asset being borrowed
    /// @param premium The premium of the flash borrow
    /// @param initiator The address that initiated the flash borrow
    /// @param params The parameters for the flash borrow
    /// @return success Whether the operation was successful
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        payable
        returns (bool)
    {
        require(msg.sender == address(nectra), UnauthorizedCaller(msg.sender, address(nectra)));
        require(initiator == address(this), UnauthorizedCaller(initiator, address(this)));

        if (asset == address(0)) {
            require(amount == msg.value, InvalidAmount(amount, msg.value));
            _increasePositionExposure(amount, premium, params);
        } else if (asset == address(nUSD)) {
            require(msg.value == 0, InvalidAmount(msg.value, 0));
            _flashClosePosition(amount, premium, params);
        } else {
            revert InvalidAsset(asset);
        }

        return true;
    }

    /// @notice get cBTC price in USD
    function getCBTCPrice() public view returns (uint256) {
        (uint256 cBTCPrice, bool isStale) = oracleAggregator.getLatestPrice();
        require(cBTCPrice > 0 && isStale == false, InvalidCBTCPrice(cBTCPrice, isStale));
        return cBTCPrice;
    }

    /*
     * Internal functions
     */

    /// @notice Internal function to handle the increase position exposure operation
    /// @param amount The amount of the asset being borrowed
    /// @param premium The premium of the flash borrow
    /// @param params The parameters for the flash borrow
    function _increasePositionExposure(uint256 amount, uint256 premium, bytes calldata params) internal {
        // Get params
        (uint256 tokenId, uint256 desiredCollateral, uint256 desiredInterestRate, uint256 maxDebt) =
            abi.decode(params, (uint256, uint256, uint256, uint256));

        uint256 swapAmountOut = amount + premium;
        // Slippage for the swap is not important because we limit the cost to maxDebt
        (uint256 swapAmountIn, uint160 sqrtPriceX96After) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(
            swapAmountOut, 30_000_000_000_000_000_000_000_000_000_000_000_000_000_000
        ); // 3 * 10^40
        // Scale the swap amount by the open fee percentage
        uint256 expectedDebt = swapAmountIn.mulWad(UNIT + nectraExternal.OPEN_FEE_PERCENTAGE()).divWad(UNIT);

        if (tokenId == 0) {
            // Create new position
            require(expectedDebt <= maxDebt, MaxDebtExceeded(expectedDebt, maxDebt));

            // Open position
            nectra.modifyPosition{value: desiredCollateral}(
                0, int256(desiredCollateral), int256(swapAmountIn), desiredInterestRate, ""
            );
        } else {
            // Check new position will not exceed maxDebt
            uint256 currentDebt = nectraExternal.getPositionDebt(tokenId);
            uint256 newDebt = currentDebt + expectedDebt;
            require(newDebt <= maxDebt, MaxDebtExceeded(newDebt, maxDebt));

            // Check if we have enough collateral to send
            uint256 collateralToSend = desiredCollateral - nectraExternal.getPositionCollateral(tokenId);
            require(collateralToSend <= address(this).balance, InvalidAmount(collateralToSend, address(this).balance));

            // Modify position
            nectra.modifyPosition{value: collateralToSend}(
                tokenId, int256(collateralToSend), int256(swapAmountIn), desiredInterestRate, ""
            );
        }

        // Sell nUSD for cBTC
        receiveAmountLock = swapAmountOut;
        nUSD.approve(address(satsumaHandler), swapAmountIn);
        satsumaHandler.swapNUSDToCBTCExactOutput(swapAmountOut, swapAmountIn, sqrtPriceX96After);

        // Repay flash loan
        nectra.repayFlashBorrow{value: swapAmountOut}();
    }

    /// @notice Internal function to handle the flash close operation
    /// @param amount The amount of the asset being borrowed
    /// @param premium The premium of the flash borrow
    /// @param params The parameters for the flash borrow
    function _flashClosePosition(uint256 amount, uint256 premium, bytes calldata params) internal {
        // Get params
        (uint256 tokenId, uint256 positionDebt, uint256 positionCollateral, uint256 interestRate) =
            abi.decode(params, (uint256, uint256, uint256, uint256));

        require(amount == positionDebt, InvalidAmount(amount, positionDebt));

        // Approve Nectra to spend nUSD
        nUSD.approve(address(nectra), amount);

        receiveAmountLock = positionCollateral;

        // Close the position by repaying all debt and withdrawing all collateral
        nectra.modifyPosition(
            tokenId,
            type(int256).min, // Withdraw all collateral
            type(int256).min, // Repay all debt
            interestRate, // Interest rate doesn't matter when closing
            "" // No permit needed
        );

        // Calculate how much collateral we need to swap to cover the flash mint repayment
        uint256 totalRepayment = amount + premium;
        // Slippage for the swap is not important because we check minCollateralOut in the external function
        (uint256 collateralToSwap, uint160 sqrtPriceX96After) =
            satsumaHandler.getCBTCToNUSDExactOutputQuote(totalRepayment, 0);

        require(
            collateralToSwap <= positionCollateral, InsufficientCollateralForSwap(positionCollateral, collateralToSwap)
        );

        // Swap collateral to nUSD to repay flash mint
        satsumaHandler.swapCBTCToNUSDExactOutput{value: collateralToSwap}(
            totalRepayment, collateralToSwap, sqrtPriceX96After
        );

        // Approve the flash mint repayment
        nUSD.approve(address(nectra), totalRepayment);
    }

    /// @notice Internal function to check if a position exists
    /// @param tokenId The token ID of the position
    function _requirePositionExists(uint256 tokenId) internal view {
        require(tokenId > 0, InvalidPositionId(tokenId));

        try nectraNFT.ownerOf(tokenId) returns (address) {}
        catch (bytes memory) {
            revert InvalidPositionId(tokenId);
        }
    }

    /// @notice Internal function to check if the caller is authorized to modify the position
    /// @param tokenId The token ID of the position
    /// @param caller The address of the caller
    /// @param permissionBitmask The bitmask of permissions required
    function _requireCallerAuthorized(uint256 tokenId, address caller, uint256 permissionBitmask) internal view {
        require(
            nectraNFT.ownerOf(tokenId) == caller || nectraNFT.authorized(tokenId, caller, permissionBitmask),
            UnauthorizedCaller(caller, nectraNFT.ownerOf(tokenId))
        );
    }

    /// @notice Only accept expected cBTC
    receive() external payable {
        require(msg.value == receiveAmountLock, InvalidAmount(msg.value, receiveAmountLock));
        receiveAmountLock = 0;
    }
}
