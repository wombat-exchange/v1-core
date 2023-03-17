// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import '../interfaces/IBribe.sol';

interface IGauge {
    function notifyRewardAmount(IERC20 token, uint256 amount) external;
}

interface IVe {
    function vote(address user, int256 voteDelta) external;
}

/// Voter can handle gauge voting. WOM rewards are distributed to different gauges (MasterWombat->LpToken pair)
/// according to the base allocation & voting weights.
///
/// veWOM holders can participate in gauge voting to determine `voteAllocation()` of the WOM emission. They can
///  allocate their vote (1 veWOM = 1 vote) to one or more gauges. WOM accumulation to a gauge is proportional
/// to the amount of vote it receives.
///
/// Real-time WOM accumulation and epoch-based WOM distribution:
/// Voting gauges accumulates WOM seconds by seconds according to the voting weight. When a user applies new
/// allocation for their votes, accumulation rate of WOM of the gauge updates immediately. Note that only whitelisted
/// gauges are able to accumulate WOM from users' votes.
/// Accumulated WOM is distributed to LP in the next epoch at an even rate. 1 epoch last for 7 days.
///
/// Base Allocation:
/// `baseAllocation` of WOM emissions is distributed to gauges according to the allocation by `owner`.
/// Other WOM emissions are deteremined by `votes` of veWOM holders.
///
/// Flow to distribute reward:
/// 1. `Voter.distribute(lpToken)` is called
/// 2. WOM index (`baseIndex` and `voteIndex`) is updated and corresponding WOM accumulated over this period (`GaugeInfo.claimable`)
///    is updated.
/// 3. At the beginning of each epoch, `GaugeInfo.claimable` amount of WOM is sent to the respective gauge
///    via `MasterWombat.notifyRewardAmount(IERC20 _lpToken, uint256 _amount)`
/// 4. MasterWombat will update the corresponding `pool.rewardRate` and `pool.periodFinish`
///
/// Bribe
/// Bribe is natively supported by `Voter`. Third Party protocols can bribe to attract more votes from veWOM holders
/// to increase WOM emissions to their tokens.
///
/// Flow of bribe:
/// 1. When users vote/unvote, `bribe.onVote` is called. The bribe contract works similar to `MultiRewarderPerSec`.
///
/// Note: This should also works with boosted pool. But it doesn't work with interest rate model
/// Note 2: Please refer to the comment of MasterWombatV3.notifyRewardAmount for front-running risk
contract Voter is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    struct GaugeInfo {
        uint104 supplyBaseIndex; // 19.12 fixed point. distributed reward per alloc point
        uint104 supplyVoteIndex; // 19.12 fixed point. distributed reward per vote weight
        uint40 nextEpochStartTime;
        uint128 claimable; // 20.18 fixed point. Rewards pending distribution in the next epoch
        bool whitelist;
        IGauge gaugeManager;
        IBribe bribe; // address of bribe
    }

    struct GaugeWeight {
        uint128 allocPoint;
        uint128 voteWeight; // total amount of votes for an LP-token
    }

    uint256 internal constant ACC_TOKEN_PRECISION = 1e12;
    uint256 internal constant EPOCH_DURATION = 7 days;

    IERC20 public wom;
    IVe public veWom;
    IERC20[] public lpTokens; // all LP tokens

    // emission related storage
    uint40 public lastRewardTimestamp; // last timestamp to count
    uint104 public baseIndex; // 19.12 fixed point. Accumulated reward per alloc point
    uint104 public voteIndex; // 19.12 fixed point. Accumulated reward per vote weight

    uint128 public totalWeight;
    uint128 public totalAllocPoint;

    uint40 public firstEpochStartTime;
    uint88 public womPerSec; // 8.18 fixed point
    uint16 public baseAllocation; // (e.g. 300 for 30%)

    mapping(IERC20 => GaugeWeight) public weights; // lpToken => gauge weight
    mapping(address => mapping(IERC20 => uint256)) public votes; // user address => lpToken => votes
    mapping(IERC20 => GaugeInfo) public infos; // lpToken => GaugeInfo

    event UpdateEmissionPartition(uint256 baseAllocation, uint256 votePartition);
    event UpdateVote(address user, IERC20 lpToken, uint256 amount);
    event DistributeReward(IERC20 lpToken, uint256 amount);

    function initialize(
        IERC20 _wom,
        IVe _veWom,
        uint88 _womPerSec,
        uint40 _startTimestamp,
        uint40 _firstEpochStartTime,
        uint16 _baseAllocation
    ) external initializer {
        require(_firstEpochStartTime >= block.timestamp, 'invalid _firstEpochStartTime');
        require(address(_wom) != address(0), 'wom address cannot be zero');
        require(address(_veWom) != address(0), 'veWom address cannot be zero');
        require(_baseAllocation <= 1000);
        require(_womPerSec <= 10000e18);

        __Ownable_init();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();

        wom = _wom;
        veWom = _veWom;
        womPerSec = _womPerSec;
        lastRewardTimestamp = _startTimestamp;
        firstEpochStartTime = _firstEpochStartTime;
        baseAllocation = _baseAllocation;
    }

    /// @dev this check save more gas than a modifier
    function _checkGaugeExist(IERC20 _lpToken) internal view {
        require(address(infos[_lpToken].gaugeManager) != address(0), 'Voter: gaugeManager not exist');
    }

    /// @notice returns LP tokens length
    function lpTokenLength() external view returns (uint256) {
        return lpTokens.length;
    }

    /// @notice getter function to return vote of a LP token for a user
    function getUserVotes(address _user, IERC20 _lpToken) external view returns (uint256) {
        return votes[_user][_lpToken];
    }

    /// @notice Vote and unvote WOM emission for LP tokens.
    /// User can vote/unvote a un-whitelisted pool. But no WOM will be emitted.
    /// Bribes are also distributed by the Bribe contract.
    /// Amount of vote should be checked by veWom.vote().
    /// This can also used to distribute bribes when _deltas are set to 0
    /// @param _lpVote address to LP tokens to vote
    /// @param _deltas change of vote for each LP tokens
    function vote(
        IERC20[] calldata _lpVote,
        int256[] calldata _deltas
    ) external nonReentrant returns (uint256[][] memory bribeRewards) {
        // 1. call _updateFor() to update WOM emission
        // 2. update related lpToken weight and total lpToken weight
        // 3. update used voting power and ensure there's enough voting power
        // 4. call IBribe.onVote() to update bribes
        require(_lpVote.length == _deltas.length, 'voter: array length not equal');

        // update voteIndex
        _distributeWom();

        uint256 voteCnt = _lpVote.length;
        int256 voteDelta;

        bribeRewards = new uint256[][](voteCnt);

        for (uint256 i; i < voteCnt; ++i) {
            IERC20 lpToken = _lpVote[i];
            _checkGaugeExist(lpToken);

            int256 delta = _deltas[i];
            uint256 originalWeight = weights[lpToken].voteWeight;
            if (delta != 0) {
                _updateFor(lpToken);

                // update vote and weight
                if (delta > 0) {
                    // vote
                    votes[msg.sender][lpToken] += uint256(delta);
                    weights[lpToken].voteWeight = to128(originalWeight + uint256(delta));
                    totalWeight += to128(uint256(delta));
                } else {
                    // unvote
                    require(votes[msg.sender][lpToken] >= uint256(-delta), 'voter: vote underflow');
                    votes[msg.sender][lpToken] -= uint256(-delta);
                    weights[lpToken].voteWeight = to128(originalWeight - uint256(-delta));
                    totalWeight -= to128(uint256(-delta));
                }

                voteDelta += delta;
                emit UpdateVote(msg.sender, lpToken, votes[msg.sender][lpToken]);
            }

            // update bribe
            if (address(infos[lpToken].bribe) != address(0)) {
                bribeRewards[i] = infos[lpToken].bribe.onVote(msg.sender, votes[msg.sender][lpToken], originalWeight);
            }
        }

        // notice veWom for the new vote, it reverts if vote is invalid
        veWom.vote(msg.sender, voteDelta);
    }

    /// @notice Claim bribes for LP tokens
    /// @dev This function looks safe from re-entrancy attack
    function claimBribes(IERC20[] calldata _lpTokens) external returns (uint256[][] memory bribeRewards) {
        bribeRewards = new uint256[][](_lpTokens.length);
        for (uint256 i; i < _lpTokens.length; ++i) {
            IERC20 lpToken = _lpTokens[i];
            _checkGaugeExist(lpToken);
            if (address(infos[lpToken].bribe) != address(0)) {
                bribeRewards[i] = infos[lpToken].bribe.onVote(
                    msg.sender,
                    votes[msg.sender][lpToken],
                    weights[lpToken].voteWeight
                );
            }
        }
    }

    /// @dev This function looks safe from re-entrancy attack
    function distribute(IERC20 _lpToken) external {
        require(msg.sender == address(infos[_lpToken].gaugeManager), 'Caller is not gauge manager');
        _checkGaugeExist(_lpToken);
        _distributeWom();
        _updateFor(_lpToken);

        uint256 _claimable = infos[_lpToken].claimable;
        // 1. distribute WOM once in each epoch
        // 2. In case WOM is not fueled, it should not create DoS
        if (
            _claimable > 0 &&
            block.timestamp >= infos[_lpToken].nextEpochStartTime &&
            wom.balanceOf(address(this)) > _claimable
        ) {
            infos[_lpToken].claimable = 0;
            infos[_lpToken].nextEpochStartTime = _getNextEpochStartTime();
            emit DistributeReward(_lpToken, _claimable);

            wom.transfer(address(infos[_lpToken].gaugeManager), _claimable);
            infos[_lpToken].gaugeManager.notifyRewardAmount(_lpToken, _claimable);
        }
    }

    /// @notice Update index for accrued WOM
    function _distributeWom() internal {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        baseIndex = to104(_getBaseIndex());
        voteIndex = to104(_getVoteIndex());
        lastRewardTimestamp = uint40(block.timestamp);
    }

    /// @notice Update `supplyBaseIndex` and `supplyVoteIndex` for the gauge
    /// @dev Assumption: gaugeManager exists and is not paused, the caller should verify it
    /// @param _lpToken address of the LP token
    function _updateFor(IERC20 _lpToken) internal {
        // calculate claimable amount before update supplyVoteIndex
        infos[_lpToken].claimable = to128(_getClaimable(_lpToken, baseIndex, voteIndex));
        infos[_lpToken].supplyBaseIndex = baseIndex;
        infos[_lpToken].supplyVoteIndex = voteIndex;
    }

    /**
     * Permisioneed functions
     */

    /// @notice update the base and vote partition
    function setBaseAllocation(uint16 _baseAllocation) external onlyOwner {
        require(_baseAllocation <= 1000);
        _distributeWom();

        emit UpdateEmissionPartition(_baseAllocation, 1000 - _baseAllocation);
        baseAllocation = _baseAllocation;
    }

    function setAllocPoint(IERC20 _lpToken, uint128 _allocPoint) external onlyOwner {
        _distributeWom();
        _updateFor(_lpToken);
        totalAllocPoint = totalAllocPoint - weights[_lpToken].allocPoint + _allocPoint;
        weights[_lpToken].allocPoint = _allocPoint;
    }

    /// @notice Add LP token into the Voter
    function add(IGauge _gaugeManager, IERC20 _lpToken, IBribe _bribe) external onlyOwner {
        require(infos[_lpToken].whitelist == false, 'voter: already added');
        require(address(_gaugeManager) != address(0));
        require(address(_lpToken) != address(0));
        require(address(infos[_lpToken].gaugeManager) == address(0), 'Voter: gaugeManager is already exist');

        infos[_lpToken].whitelist = true;
        infos[_lpToken].gaugeManager = _gaugeManager;
        infos[_lpToken].bribe = _bribe; // 0 address is allowed
        infos[_lpToken].nextEpochStartTime = _getNextEpochStartTime();
        lpTokens.push(_lpToken);
    }

    function setWomPerSec(uint88 _womPerSec) external onlyOwner {
        require(_womPerSec <= 10000e18, 'reward rate too high'); // in case `voteIndex` overflow
        _distributeWom();
        womPerSec = _womPerSec;
    }

    /// @notice Pause vote emission of WOM tokens for the gauge.
    /// Users can still vote/unvote and receive bribes.
    function pauseVoteEmission(IERC20 _lpToken) external onlyOwner {
        require(infos[_lpToken].whitelist, 'voter: not whitelisted');
        _checkGaugeExist(_lpToken);

        _distributeWom();
        _updateFor(_lpToken);

        infos[_lpToken].whitelist = false;
    }

    /// @notice Resume vote accumulation of WOM tokens for the gauge.
    function resumeVoteEmission(IERC20 _lpToken) external onlyOwner {
        require(infos[_lpToken].whitelist == false, 'voter: not paused');
        _checkGaugeExist(_lpToken);

        // catch up supplyVoteIndex
        _distributeWom();
        _updateFor(_lpToken);

        infos[_lpToken].whitelist = true;
    }

    /// @notice Pause vote accumulation of WOM tokens for all assets
    /// Users can still vote/unvote and receive bribes.
    function pauseAll() external onlyOwner {
        _distributeWom();
        uint256 len = lpTokens.length;
        for (uint256 i; i < len; i++) {
            _updateFor(lpTokens[i]);
        }

        _pause();
    }

    /// @notice Resume vote accumulation of WOM tokens for all assets
    function resumeAll() external onlyOwner {
        _distributeWom();
        uint256 len = lpTokens.length;
        for (uint256 i; i < len; i++) {
            _updateFor(lpTokens[i]);
        }

        _unpause();
    }

    /// @notice get gaugeManager address for LP token
    function setGauge(IERC20 _lpToken, IGauge _gaugeManager) external onlyOwner {
        require(address(_gaugeManager) != address(0));
        _checkGaugeExist(_lpToken);

        infos[_lpToken].gaugeManager = _gaugeManager;
    }

    /// @notice get bribe address for LP token
    function setBribe(IERC20 _lpToken, IBribe _bribe) external onlyOwner {
        _checkGaugeExist(_lpToken);

        infos[_lpToken].bribe = _bribe; // 0 address is allowed
    }

    /// @notice In case we need to manually migrate WOM funds from Voter
    /// Sends all remaining wom from the contract to the owner
    function emergencyWomWithdraw() external onlyOwner {
        // SafeERC20 is not needed as WOM will revert if transfer fails
        wom.transfer(address(msg.sender), wom.balanceOf(address(this)));
    }

    // TODO: create PR to check in this
    /// @notice avoids loosing funds in case there is any tokens sent to this contract
    /// @dev only to be called by owner
    // function emergencyTokenWithdraw(address token) public onlyOwner {
    //     // send that balance back to owner
    //     if (token == address(0)) {
    //         // is native token
    //         (bool success, ) = msg.sender.call{value: address(this).balance}('');
    //         require(success, 'Transfer failed');
    //     } else {
    //         IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    //     }
    // }

    /**
     * Read-only functions
     */

    function voteAllocation() external view returns (uint256) {
        return 1000 - baseAllocation;
    }

    /// @notice Get pending bribes for LP tokens
    function pendingBribes(
        IERC20[] calldata _lpTokens,
        address _user
    )
        external
        view
        returns (
            IERC20[][] memory bribeTokenAddresses,
            string[][] memory bribeTokenSymbols,
            uint256[][] memory bribeRewards
        )
    {
        bribeTokenAddresses = new IERC20[][](_lpTokens.length);
        bribeTokenSymbols = new string[][](_lpTokens.length);
        bribeRewards = new uint256[][](_lpTokens.length);
        for (uint256 i; i < _lpTokens.length; ++i) {
            IERC20 lpToken = _lpTokens[i];
            if (address(infos[lpToken].bribe) != address(0)) {
                bribeRewards[i] = infos[lpToken].bribe.pendingTokens(_user);
                bribeTokenAddresses[i] = infos[lpToken].bribe.rewardTokens();

                uint256 len = bribeTokenAddresses[i].length;
                bribeTokenSymbols[i] = new string[](len);

                for (uint256 j; j < len; ++j) {
                    if (address(bribeTokenAddresses[i][j]) == address(0)) {
                        bribeTokenSymbols[i][j] = 'BNB';
                    } else {
                        bribeTokenSymbols[i][j] = IERC20Metadata(address(bribeTokenAddresses[i][j])).symbol();
                    }
                }
            }
        }
    }

    /// @notice Amount of pending WOM for the LP token
    function pendingWom(IERC20 _lpToken) external view returns (uint256) {
        return _getClaimable(_lpToken, _getBaseIndex(), _getVoteIndex());
    }

    function _getBaseIndex() internal view returns (uint256) {
        if (block.timestamp <= lastRewardTimestamp || totalAllocPoint == 0 || paused()) {
            return baseIndex;
        }

        uint256 secondsElapsed = block.timestamp - lastRewardTimestamp;
        // use `max(totalAllocPoint, 1e18)` in case the value overflows uint104
        return
            baseIndex +
            (secondsElapsed * womPerSec * baseAllocation * ACC_TOKEN_PRECISION) /
            max(totalAllocPoint, 1e18) /
            1000;
    }

    /// @notice Calculate the latest value of `voteIndex`
    function _getVoteIndex() internal view returns (uint256) {
        if (block.timestamp <= lastRewardTimestamp || totalWeight == 0 || paused()) {
            return voteIndex;
        }

        uint256 secondsElapsed = block.timestamp - lastRewardTimestamp;
        // use `max(totalWeight, 1e18)` in case the value overflows uint104
        return
            voteIndex +
            (secondsElapsed * womPerSec * (1000 - baseAllocation) * ACC_TOKEN_PRECISION) /
            max(totalWeight, 1e18) /
            1000;
    }

    /// @notice Calculate the latest amount of `claimable` for a gauge
    function _getClaimable(IERC20 _lpToken, uint256 _baseIndex, uint256 _voteIndex) internal view returns (uint256) {
        uint256 baseIndexDelta = _baseIndex - infos[_lpToken].supplyBaseIndex;
        uint256 _baseShare = (weights[_lpToken].allocPoint * baseIndexDelta) / ACC_TOKEN_PRECISION;

        if (!infos[_lpToken].whitelist) {
            return infos[_lpToken].claimable + _baseShare;
        }

        uint256 voteIndexDelta = _voteIndex - infos[_lpToken].supplyVoteIndex;
        uint256 _voteShare = (weights[_lpToken].voteWeight * voteIndexDelta) / ACC_TOKEN_PRECISION;

        return infos[_lpToken].claimable + _baseShare + _voteShare;
    }

    /// @notice Get the start timestamp of the next epoch
    function _getNextEpochStartTime() internal view returns (uint40) {
        if (block.timestamp < firstEpochStartTime) {
            return firstEpochStartTime;
        }

        uint256 epochCount = (block.timestamp - firstEpochStartTime) / EPOCH_DURATION;
        return uint40(firstEpochStartTime + (epochCount + 1) * EPOCH_DURATION);
    }

    function to128(uint256 val) internal pure returns (uint128) {
        require(val <= type(uint128).max, 'uint128 overflow');
        return uint128(val);
    }

    function to104(uint256 val) internal pure returns (uint104) {
        if (val > type(uint104).max) revert('uint104 overflow');
        return uint104(val);
    }

    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }
}
