// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";
import { OmniConstants } from "../../contracts/interfaces/IOmniBracketTypes.sol";

/**
 * @title MockOmniSystemContract
 * @notice Byte-accurate emulator of Reactive Omni's SystemContract at `0x8888...8888`,
 *         modeling subscriptions, `requestCallbackV_1_0`, reserve/debt accounting, and `pay()`.
 */
contract MockOmniSystemContract is ISystemContract {
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct QueuedCallback {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] public subscriptions;
    QueuedCallback[] internal callbackQueue;

    mapping(address => uint256) public reserves;
    mapping(address => uint256) internal debts;

    uint256 public _gasPriceCoeffPer1000 = 1000;
    uint256 public _extraGas = 100_000;
    uint256 public _maxChargeGas = 50_000;

    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        CallbackVersion version,
        bytes configuration
    );

    error InvalidCallbackVersion();

    receive() external payable override {
        _credit(msg.sender, msg.value);
    }

    function depositTo(address target_) external payable {
        _credit(target_, msg.value);
    }

    function debt(address contract_) external view override returns (uint256) {
        return debts[contract_];
    }

    function setMockDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function chargeFee(address target_, uint256 feeAmount_) external {
        uint256 res = reserves[target_];
        if (res >= feeAmount_) {
            reserves[target_] = res - feeAmount_;
            return;
        }
        uint256 shortfall = feeAmount_ - res;
        reserves[target_] = 0;
        debts[target_] += shortfall;

        try IPayer(payable(target_)).pay{ gas: _maxChargeGas }(debts[target_]) {} catch {}
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        require(
            chainId_ != 0 ||
                contract_ != address(0) ||
                topic0_ != REACTIVE_IGNORE ||
                topic1_ != REACTIVE_IGNORE ||
                topic2_ != REACTIVE_IGNORE ||
                topic3_ != REACTIVE_IGNORE,
            "At least one criterion required"
        );
        subscriptions.push(
            Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_
            })
        );
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        uint256 len = subscriptions.length;
        for (uint256 i = 0; i < len; ++i) {
            Subscription storage s = subscriptions[i];
            if (
                s.subscriber == msg.sender &&
                s.chainId == chainId_ &&
                s.contractAddress == contract_ &&
                s.topic0 == topic0_ &&
                s.topic1 == topic1_ &&
                s.topic2 == topic2_ &&
                s.topic3 == topic3_
            ) {
                subscriptions[i] = subscriptions[len - 1];
                subscriptions.pop();
                return;
            }
        }
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) external override {
        if (version_ != CallbackVersion.V_1_0) revert InvalidCallbackVersion();
        CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
        _enqueueCallback(msg.sender, cfg);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        _enqueueCallback(msg.sender, config_);
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function drainQueuedCallbacks() external returns (QueuedCallback[] memory batch) {
        uint256 len = callbackQueue.length;
        batch = new QueuedCallback[](len);
        for (uint256 i = 0; i < len; ++i) {
            batch[i] = callbackQueue[i];
        }
        delete callbackQueue;
    }

    function getMatchingSubscribers(IReactive.LogRecord memory log_) external view returns (address[] memory matched) {
        uint256 len = subscriptions.length;
        address[] memory temp = new address[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; ++i) {
            Subscription storage s = subscriptions[i];
            if (debts[s.subscriber] > 0) continue;
            if (s.chainId != 0 && s.chainId != log_.chainId) continue;
            if (s.contractAddress != address(0) && s.contractAddress != log_.contractAddress) continue;
            if (s.topic0 != REACTIVE_IGNORE && s.topic0 != log_.topic0) continue;
            if (s.topic1 != REACTIVE_IGNORE && s.topic1 != log_.topic1) continue;
            if (s.topic2 != REACTIVE_IGNORE && s.topic2 != log_.topic2) continue;
            if (s.topic3 != REACTIVE_IGNORE && s.topic3 != log_.topic3) continue;

            bool duplicate = false;
            for (uint256 j = 0; j < count; ++j) {
                if (temp[j] == s.subscriber) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                temp[count++] = s.subscriber;
            }
        }

        matched = new address[](count);
        for (uint256 k = 0; k < count; ++k) {
            matched[k] = temp[k];
        }
    }

    function _enqueueCallback(address sender_, CallbackConfiguration_V_1_0 memory cfg_) internal {
        // Reactive Network ignores callback requests below 100,000 gas.
        if (cfg_.gasLimit < OmniConstants.MIN_CALLBACK_GAS_LIMIT) {
            return;
        }
        callbackQueue.push(
            QueuedCallback({
                sender: sender_,
                chainId: cfg_.chainId,
                recipient: cfg_.recipient,
                gasLimit: cfg_.gasLimit,
                payload: cfg_.payload
            })
        );
        emit CallbackRequest(cfg_.chainId, sender_, cfg_.recipient, CallbackVersion.V_1_0, abi.encode(cfg_));
    }

    function _credit(address target_, uint256 amount_) internal {
        uint256 owed = debts[target_];
        if (owed > 0) {
            if (amount_ >= owed) {
                debts[target_] = 0;
                reserves[target_] += (amount_ - owed);
            } else {
                debts[target_] = owed - amount_;
            }
        } else {
            reserves[target_] += amount_;
        }
    }
}

/**
 * @title MockOmniCallbackProxy
 * @notice Byte-accurate emulator of Destination CallbackProxy (e.g. `0x476F44...` on Base Sepolia),
 *         enforcing code checks, zero-debt checks, gas overhead deductions, first-arg sender injection,
 *         and post-delivery fee charging.
 */
contract MockOmniCallbackProxy {
    mapping(address => uint256) public reserves;
    mapping(address => uint256) internal debts;

    uint256 public _gasPriceCoeffPer1000 = 1100;
    uint256 public _extraGas = 80_000;
    uint256 public _maxChargeGas = 50_000;

    event CallbackDelivered(address indexed reactiveSender, address indexed recipient, bool success, bytes returnData);
    event CallbackFailure(address indexed recipient, bytes returnData);

    error NotAContract(address target);
    error InDebt(address target, uint256 debtAmount);
    error InsufficientGas(uint64 provided, uint256 overhead);
    error PayloadTooShort(uint256 byteLen);

    receive() external payable {
        _credit(msg.sender, msg.value);
    }

    function depositTo(address target_) external payable {
        _credit(target_, msg.value);
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    function setMockDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    /**
     * @notice Delivers a callback just like Reactive Signer -> CallbackProxy on Base Sepolia:
     *         overwrites bytes [4..36] of `payload_` with `abi.encode(reactiveSender_)`.
     */
    function deliver(
        address reactiveSender_,
        address recipient_,
        uint64 gasLimit_,
        bytes memory payload_,
        uint256 simulatedFeeWei_
    ) external returns (bool success, bytes memory returnData) {
        if (recipient_.code.length == 0) revert NotAContract(recipient_);
        if (debts[recipient_] > 0) revert InDebt(recipient_, debts[recipient_]);

        uint256 overhead = _extraGas + _maxChargeGas;
        if (uint256(gasLimit_) <= overhead) revert InsufficientGas(gasLimit_, overhead);
        if (payload_.length < 36) revert PayloadTooShort(payload_.length);

        bytes memory patched = bytes.concat(payload_);
        bytes32 paddedSender = bytes32(uint256(uint160(reactiveSender_)));
        // Overwrite first ABI parameter slot (bytes 4..36 immediately after 4-byte selector).
        assembly {
            mstore(add(add(patched, 0x20), 4), paddedSender)
        }

        uint256 forwardGas = uint256(gasLimit_) - overhead;
        (success, returnData) = recipient_.call{ gas: forwardGas }(patched);

        if (!success) {
            emit CallbackFailure(recipient_, returnData);
        }
        emit CallbackDelivered(reactiveSender_, recipient_, success, returnData);

        if (simulatedFeeWei_ > 0) {
            _charge(recipient_, simulatedFeeWei_);
        }
    }

    function _charge(address target_, uint256 feeWei_) internal {
        uint256 res = reserves[target_];
        if (res >= feeWei_) {
            reserves[target_] = res - feeWei_;
            return;
        }
        uint256 shortfall = feeWei_ - res;
        reserves[target_] = 0;
        debts[target_] += shortfall;

        try IPayer(payable(target_)).pay{ gas: _maxChargeGas }(debts[target_]) {} catch {}
    }

    function _credit(address target_, uint256 amount_) internal {
        uint256 owed = debts[target_];
        if (owed > 0) {
            if (amount_ >= owed) {
                debts[target_] = 0;
                reserves[target_] += (amount_ - owed);
            } else {
                debts[target_] = owed - amount_;
            }
        } else {
            reserves[target_] += amount_;
        }
    }
}
