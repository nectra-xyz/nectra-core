// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraViews} from "src/NectraViews.sol";
import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraLiquidate} from "src/NectraLiquidate.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NectraFlash} from "src/NectraFlash.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Nectra
/// @notice Core contract for managing collateralized debt positions
/// @dev Handles position creation, modification, and management with interest rate buckets
/// @dev Holds the deposited cBTC balance for the system
contract Nectra is
    NectraBase,
    NectraRedeem,
    NectraLiquidate,
    NectraFlash,
    NectraViews,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using NectraMathLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    error MinimumDepositNotMet(uint256 deposit, uint256 minimumDeposit);
    error MinimumDebtNotMet(uint256 debt, uint256 minimumDebt);
    error InvalidCollateralizationRatio(uint256 cratio, uint256 minCratio);
    error CollateralMismatch();
    error NotOwnerNorApproved();
    error RedemptionBufferPositionAlreadyExists(uint256 bufferId);
    error RedemptionBufferPositionManagerAlreadySet(address bufferManager);
    error InvalidManager(address manager);

    /// @notice Emitted when a position is modified
    /// @param tokenId ID of the position being modified
    /// @param depositOrWithdraw Amount of collateral deposited (positive) or withdrawn (negative)
    /// @param borrowOrRepay Amount of debt borrowed (positive) or repaid (negative)
    /// @param collateral Total collateral in the position after modification
    /// @param debt Total debt in the position after modification
    /// @param interestRate New interest rate for the position
    /// @param operator Address that initiated the modification
    /// @param fee Fees paid for the modification
    event ModifyPosition(
        uint256 indexed tokenId,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 collateral,
        uint256 debt,
        uint256 interestRate,
        address indexed operator,
        uint256 fee
    );

    /// @notice Emitted when the system set interest rate is set
    /// @param interestRate The system set interest rate
    event SystemInterestRateSet(uint256 interestRate);

    /// @notice Emitted when the redemption buffer position id is set
    /// @param redemptionBufferPositionId The redemption buffer position id
    event RedemptionBufferPositionIdSet(uint256 redemptionBufferPositionId);

    /// @notice Emitted when the redemption buffer position manager is set
    /// @param redemptionBufferPositionManager The redemption buffer position manager
    event RedemptionBufferPositionManagerSet(address redemptionBufferPositionManager);

    /// @param params System parameters defined in NectraBase
    function initialize(SystemParams memory params) public initializer {
        setSystemParams(params);

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @notice Creates, modifies or closes a collateralized debt position
    /// @dev Handles interest rate change, debt issuance/repayment, and collateral deposit/withdraw
    /// @dev Requires appropriate permissions for the operation being performed if not position owner
    /// @param tokenId Existing position tokenId (0 for new position)
    /// @param depositOrWithdraw Amount of collateral to deposit (+) or withdraw (- or type(int256).min to close)
    /// @param borrowOrRepay Amount of nUSD to borrow (+) or repay (- or type(int256).min to close)
    /// @param permit Optional permit data for NUSD token approval
    /// @return tokenId The ID of the position being modified
    /// @return depositOrWithdraw Actual amount of collateral deposited or withdrawn
    /// @return borrowOrRepay Actual amount of nUSD borrowed or repaid
    /// @return collateral The total collateral in the position after modification
    /// @return effectiveDebt The total effective debt of the position after modification
    function modifyPosition(uint256 tokenId, int256 depositOrWithdraw, int256 borrowOrRepay, bytes calldata permit)
        external
        payable
        returns (uint256, int256, int256, uint256, uint256)
    {
        NectraLib.GlobalState memory global;
        NectraLib.BucketState memory bucket;
        NectraLib.PositionState memory position;
        NectraLib.BucketState memory oldBucket;

        // use system interest rate
        uint256 interestRate = _systemInterestRate();

        if (tokenId != 0) {
            // load bucket using existing position interest rate
            (position, bucket, global) = _loadAndUpdateState(tokenId);

            if (tokenId == _redemptionBufferPositionId()) {
                require(msg.sender == _redemptionBufferPositionManager(), NotOwnerNorApproved());
                // buffer position has no interest rate
                interestRate = 0;
            } else {
                uint256 permissionBitMask;

                if (borrowOrRepay < 0) {
                    permissionBitMask |= 1 << uint256(NectraNFT.Permission.Repay);
                } else if (borrowOrRepay > 0) {
                    permissionBitMask |= 1 << uint256(NectraNFT.Permission.Borrow);
                }
                if (depositOrWithdraw < 0) {
                    permissionBitMask |= 1 << uint256(NectraNFT.Permission.Withdraw);
                } else if (depositOrWithdraw > 0) {
                    permissionBitMask |= 1 << uint256(NectraNFT.Permission.Deposit);
                }

                require(
                    NectraNFT(_systemConfig().NECTRA_NFT_ADDRESS).authorized(tokenId, msg.sender, permissionBitMask),
                    NotOwnerNorApproved()
                );
            }
        } else {
            // load bucket using system interest rate
            (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _core()._epochs[interestRate]);
            position = NectraLib.PositionState({
                tokenId: NectraNFT(_systemConfig().NECTRA_NFT_ADDRESS).mint(msg.sender),
                collateral: 0,
                debtShares: 0,
                lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                interestRate: interestRate,
                bucketEpoch: bucket.epoch
            });
        }

        // if bucket is new, increment the num active buckets
        if (bucket.globalDebtShares == 0 && borrowOrRepay > 0) {
            _storeNumActiveBuckets(_numActiveBuckets() + 1);
        }

        uint256 effectiveDebt;
        uint256 fee;
        (depositOrWithdraw, borrowOrRepay,, effectiveDebt, fee) =
            _modifyPosition(position, bucket, oldBucket, global, depositOrWithdraw, borrowOrRepay, interestRate);

        require(
            depositOrWithdraw < 0 && msg.value == 0 || uint256(depositOrWithdraw) == msg.value, CollateralMismatch()
        );

        if (oldBucket.lastUpdateTime != 0) {
            _finalizeBucket(oldBucket);
        }

        _finalize(position, bucket, global);

        if (borrowOrRepay > 0) {
            // mint NUSD
            NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).mint(msg.sender, uint256(borrowOrRepay));
        } else if (borrowOrRepay < 0) {
            if (permit.length > 0) {
                // solhint-disable-next-line avoid-low-level-calls
                _systemConfig().NUSD_TOKEN_ADDRESS.call(abi.encodePacked(NUSDToken.permit.selector, permit));
            }
            // burn NUSD
            NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).burn(msg.sender, uint256(-borrowOrRepay));
        }

        if (depositOrWithdraw < 0) {
            // transfer collateral to the contract
            address(msg.sender).safeTransferETH(uint256(-depositOrWithdraw));
        }

        emit ModifyPosition(
            position.tokenId,
            depositOrWithdraw,
            borrowOrRepay,
            position.collateral,
            effectiveDebt,
            interestRate,
            msg.sender,
            fee
        );

        return (position.tokenId, depositOrWithdraw, borrowOrRepay, position.collateral, effectiveDebt);
    }

    /// @notice Creates the redemption buffer position
    /// @dev Only callable by the DAO
    /// @param collateral Amount of collateral to deposit
    /// @param debt Amount of nUSD to borrow
    /// @param manager The manager of the buffer position
    /// @return tokenId The ID of the position being modified
    /// @return depositOrWithdraw Actual amount of collateral deposited or withdrawn
    /// @return borrowOrRepay Actual amount of nUSD borrowed or repaid
    /// @return collateral The total collateral in the position after modification
    /// @return effectiveDebt The total effective debt of the position after modification
    function createRedemptionBufferPosition(uint256 collateral, uint256 debt, address manager)
        external
        payable
        onlyOwner
        returns (uint256, int256, int256, uint256, uint256)
    {
        uint256 existingBufferId = _redemptionBufferPositionId();
        address existingBufferManager = _redemptionBufferPositionManager();
        // prevent this function from being used to manage the position
        require(existingBufferId == 0, RedemptionBufferPositionAlreadyExists(existingBufferId));
        require(existingBufferManager == address(0), RedemptionBufferPositionManagerAlreadySet(existingBufferManager));
        require(manager != address(0), InvalidManager(manager));
        require(collateral == msg.value, CollateralMismatch());

        NectraLib.GlobalState memory global;
        NectraLib.BucketState memory bucket;
        NectraLib.PositionState memory position;
        NectraLib.BucketState memory oldBucket;

        // buffer position has no interest rate
        uint256 interestRate = 0;
        uint256 tokenId = NectraNFT(_systemConfig().NECTRA_NFT_ADDRESS).mint(manager);

        // set buffer position id and manager
        _storeRedemptionBufferPositionId(tokenId);
        _storeRedemptionBufferPositionManager(manager);

        // create new position
        (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _core()._epochs[interestRate]);
        position = NectraLib.PositionState({
            tokenId: tokenId,
            collateral: 0,
            debtShares: 0,
            lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            interestRate: interestRate,
            bucketEpoch: bucket.epoch
        });

        // if bucket is new, increment the num active buckets
        if (bucket.globalDebtShares == 0 && debt > 0) {
            _storeNumActiveBuckets(_numActiveBuckets() + 1);
        }

        (int256 deposit, int256 borrow,, uint256 effectiveDebt, uint256 fee) =
            _modifyPosition(position, bucket, oldBucket, global, int256(collateral), int256(debt), interestRate);

        if (oldBucket.lastUpdateTime != 0) {
            _finalizeBucket(oldBucket);
        }

        _finalize(position, bucket, global);

        if (borrow > 0) {
            NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).mint(manager, uint256(borrow));
        }

        emit ModifyPosition(tokenId, deposit, borrow, position.collateral, effectiveDebt, interestRate, msg.sender, fee);

        return (tokenId, deposit, borrow, position.collateral, effectiveDebt);
    }

    /// @notice Simulates a position modification to preview the outcome
    /// @dev Returns the actual amounts that would be deposited/withdrawn and borrowed/repaid
    /// @param tokenId Existing position tokenId (0 for new position)
    /// @param depositOrWithdraw Amount of collateral to deposit (+) or withdraw (- or type(int256).min to close)
    /// @param borrowOrRepay Amount of nUSD to borrow (+) or repay (- or type(int256).min to close)
    /// @return depositOrWithdraw Actual amount of collateral that would be deposited or withdrawn
    /// @return borrowOrRepay Actual amount of nUSD that would be borrowed or repaid
    /// @return collateral The total collateral in the position after modification
    /// @return effectiveDebt The total effective debt of the position after modification
    /// @return fee Fixed rate open fee
    function quoteModifyPosition(uint256 tokenId, int256 depositOrWithdraw, int256 borrowOrRepay)
        external
        view
        returns (int256, int256, uint256, uint256, uint256)
    {
        NectraLib.GlobalState memory global;
        NectraLib.BucketState memory bucket;
        NectraLib.PositionState memory position;
        NectraLib.BucketState memory oldBucket;

        // use system interest rate
        uint256 interestRate = _systemInterestRate();

        {
            if (tokenId != 0) {
                // load bucket using existing position interest rate
                (position, bucket, global) = _loadAndUpdateState(tokenId);
            } else {
                // load bucket using system interest rate
                (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _core()._epochs[interestRate]);
                position = NectraLib.PositionState({
                    tokenId: 0,
                    collateral: 0,
                    debtShares: 0,
                    lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                    lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                    interestRate: interestRate,
                    bucketEpoch: bucket.epoch
                });
            }
        }

        return _modifyPosition(position, bucket, oldBucket, global, depositOrWithdraw, borrowOrRepay, interestRate);
    }

    /// @notice Internal function to modify a position's state
    /// @dev Handles all position modifications including interest rate changes
    /// @param position Current position state
    /// @param bucket Current bucket state
    /// @param oldBucket Previous bucket state (if changing interest rates)
    /// @param global Current global state
    /// @param depositOrWithdraw Amount of collateral to deposit or withdraw
    /// @param borrowOrRepay Amount of nUSD to borrow or repay
    /// @param interestRate Desired interest rate bucket
    /// @return depositOrWithdraw Actual amount of collateral to deposit or withdraw
    /// @return borrowOrRepay Actual amount of nUSD to borrow or repay
    /// @return collateral Total collateral in the position after modification
    /// @return effectiveDebt Total effective debt in the position after modification
    /// @return fee Fixed rate open fee
    function _modifyPosition(
        NectraLib.PositionState memory position,
        NectraLib.BucketState memory bucket,
        NectraLib.BucketState memory oldBucket,
        NectraLib.GlobalState memory global,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 interestRate
    ) internal view returns (int256, int256, uint256, uint256, uint256) {
        if (depositOrWithdraw < 0) {
            // Cannot withdraw collateral if a flash borrow is active
            _requireFlashBorrowUnlocked();
        }

        uint256 fixedRateOpenFee = 0;

        // calculate fixed rate fee on new debt, excluding the buffer position
        if (borrowOrRepay > 0 && interestRate > 0) {
            fixedRateOpenFee = uint256(borrowOrRepay).mulWad(_systemConfig().OPEN_FEE_PERCENTAGE);
        }

        uint256 effectiveDebt =
            NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up) + fixedRateOpenFee;

        // Cap withdrawal to available collateral
        if (depositOrWithdraw + position.collateral.toInt256() < 0) {
            depositOrWithdraw = -int256(position.collateral);
        }

        // Cap repayment to current debt + fees
        if (borrowOrRepay + effectiveDebt.toInt256() < 0) {
            borrowOrRepay = -int256(effectiveDebt);
        }

        global.fees += fixedRateOpenFee;

        NectraLib.modifyPosition({
            position: position,
            bucket: bucket,
            global: global,
            collateralDiff: depositOrWithdraw,
            debtDiff: borrowOrRepay + int256(fixedRateOpenFee)
        });

        uint256 finalEffectiveDebt = uint256(int256(effectiveDebt) + borrowOrRepay);

        if (
            // only migrate if position has debt
            // only migrate if interest rate changes and not buffer position
            // only migrate if position is decreasing c-ratio
            finalEffectiveDebt > 0 && (interestRate != position.interestRate)
                && (borrowOrRepay > 0 || depositOrWithdraw < 0)
        ) {
            NectraLib.copy(oldBucket, bucket);
            NectraLib.copy(bucket, _loadAndUpdateBucketState(interestRate, _core()._epochs[interestRate], global));

            NectraLib.migrateBucket({position: position, srcBucket: oldBucket, dstBucket: bucket, global: global});
        }

        // Final safety checks to ensure modification is valid
        require(
            position.collateral >= _systemConfig().MINIMUM_COLLATERAL || position.collateral == 0,
            MinimumDepositNotMet(position.collateral, _systemConfig().MINIMUM_COLLATERAL)
        );
        require(
            finalEffectiveDebt >= _systemConfig().MINIMUM_BORROW
                || (finalEffectiveDebt == 0 && position.collateral == 0),
            MinimumDebtNotMet(finalEffectiveDebt, _systemConfig().MINIMUM_BORROW)
        );

        // Can always improve c-ratio
        if (finalEffectiveDebt > 0 && (borrowOrRepay > 0 || depositOrWithdraw < 0)) {
            uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

            // Check system collateralization ratio
            require(
                global.debt + global.unrealizedLiquidatedDebt == 0
                    || (address(this).balance).mulDiv(collateralPrice, global.debt + global.unrealizedLiquidatedDebt)
                        >= _systemConfig().ISSUANCE_RATIO,
                InsufficientCollateral()
            );

            uint256 cratio = position.collateral.mulWad(collateralPrice).divWad(finalEffectiveDebt);

            // Check position collateralization ratio
            require(
                cratio >= _systemConfig().ISSUANCE_RATIO,
                InvalidCollateralizationRatio(cratio, _systemConfig().ISSUANCE_RATIO)
            );
        }

        return (depositOrWithdraw, borrowOrRepay, position.collateral, finalEffectiveDebt, fixedRateOpenFee);
    }

    /// @notice Updates an existing position's accounting and finalizes state
    /// @dev Updates accumulated interest and fees for a position
    /// @param tokenId The tokenId of the position to update
    function updatePosition(uint256 tokenId) external {
        (
            NectraLib.PositionState memory position,
            NectraLib.BucketState memory bucket,
            NectraLib.GlobalState memory global
        ) = _loadAndUpdateState(tokenId);

        _finalize(position, bucket, global);
    }

    /// @notice Updates the bucket state for a specific interest rate
    /// @dev Finalizes the bucket state and updates global state
    /// @param interestRate The interest rate bucket to update
    function updateBucket(uint256 interestRate) external {
        NectraLib.BucketState memory bucket;
        NectraLib.GlobalState memory global;

        (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _core()._epochs[interestRate]);

        _finalizeBucket(bucket);
        _finalizeGlobal(global);
    }

    /// @notice Gets the system set interest rate
    /// @return The system set interest rate
    function getSystemInterestRate() external view returns (uint256) {
        return _systemInterestRate();
    }

    /// @notice Stores the system set interest rate
    /// @dev Only callable by the DAO
    /// @param interestRate The system set interest rate to set
    function storeSystemInterestRate(uint256 interestRate) external onlyOwner {
        _storeSystemInterestRate(interestRate);

        emit SystemInterestRateSet(interestRate);
    }

    /// @notice Gets the redemption buffer position id
    /// @return The redemption buffer position id
    function getRedemptionBufferPositionId() external view returns (uint256) {
        return _redemptionBufferPositionId();
    }

    /// @notice Gets the redemption buffer position manager
    /// @return The redemption buffer position manager
    function getRedemptionBufferPositionManager() external view returns (address) {
        return _redemptionBufferPositionManager();
    }

    /// @notice Stores the redemption buffer position id
    /// @dev Only callable by the DAO
    /// @param redemptionBufferPositionId The redemption buffer position id to store
    function storeRedemptionBufferPositionId(uint256 redemptionBufferPositionId) external onlyOwner {
        _storeRedemptionBufferPositionId(redemptionBufferPositionId);

        emit RedemptionBufferPositionIdSet(redemptionBufferPositionId);
    }

    /// @notice Stores the redemption buffer position manager
    /// @dev Only callable by the DAO
    /// @param redemptionBufferPositionManager The redemption buffer position manager to store
    function storeRedemptionBufferPositionManager(address redemptionBufferPositionManager) external onlyOwner {
        _storeRedemptionBufferPositionManager(redemptionBufferPositionManager);

        emit RedemptionBufferPositionManagerSet(redemptionBufferPositionManager);
    }

    /// @notice Authorizes the upgrade of the implementation contract
    /// @dev Required by UUPSUpgradeable to authorize upgrades
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
