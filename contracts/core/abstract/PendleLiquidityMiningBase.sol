// SPDX-License-Identifier: MIT
/*
 * MIT License
 * ===========
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 */
pragma solidity 0.7.6;

import "../../libraries/FactoryLib.sol";
import "../../libraries/MathLib.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../interfaces/IPendleRouter.sol";
import "../../interfaces/IPendleForge.sol";
import "../../interfaces/IPendleAaveForge.sol";
import "../../interfaces/IPendleMarketFactory.sol";
import "../../interfaces/IPendleMarket.sol";
import "../../interfaces/IPendleData.sol";
import "../../interfaces/IPendleLpHolder.sol";
import "../../core/PendleLpHolder.sol";
import "../../interfaces/IPendleLiquidityMining.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../../periphery/Permissions.sol";
import "../../periphery/PendleLiquidityMiningNonReentrant.sol";

/**
    @dev things that must hold in this contract:
     - If an account's stake information is updated (hence lastTimeUserStakeUpdated is changed),
        then his pending rewards are calculated as well
        (and saved in availableRewardsForEpoch[user][epochId])
 */
abstract contract PendleLiquidityMiningBase is
    IPendleLiquidityMining,
    Permissions,
    PendleLiquidityMiningNonReentrant
{
    using Math for uint256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserExpiries {
        uint256[] expiries;
        mapping(uint256 => bool) hasExpiry;
    }

    /* availableRewardsForEpoch[account][epochId] is the amount of PENDLEs the account
        can withdraw at the beginning of epochId*/
    struct EpochData {
        mapping(uint256 => uint256) stakeUnitsForExpiry;
        mapping(uint256 => uint256) lastUpdatedForExpiry;
        mapping(address => uint256) availableRewardsForUser;
        mapping(address => mapping(uint256 => uint256)) stakeUnitsForUser;
        uint256 settingId;
        uint256 totalRewards;
    }

    struct RewardsData {
        uint256 stakeUnitsForUser;
        uint256 settingId;
        uint256 rewardsForMarket;
        uint256 rewardsPerVestingEpoch;
    }

    struct ExpiryData {
        mapping(address => uint256) lastTimeUserStakeUpdated;
        uint256 totalStakeLP;
        address lpHolder;
        mapping(address => uint256) balances;
        // storage for interests stuff
        uint256 lastNYield;
        uint256 paramL;
        mapping(address => uint256) lastParamL;
    }

    struct LatestSetting {
        uint256 id;
        uint256 firstEpochToApply;
    }

    IPendleRouter public router;
    IPendleMarketFactory public marketFactory;
    IPendleData public data;
    address public override pendleTokenAddress;
    bytes32 public override forgeId;
    address internal forge;
    bytes32 public override marketFactoryId;

    address public override underlyingAsset;
    address public override baseToken;
    uint256 public override startTime;
    uint256 public override epochDuration;
    uint256 public override numberOfEpochs;
    uint256 public override vestingEpochs;
    bool public funded;

    uint256[] public allExpiries;
    uint256 private constant ALLOCATION_DENOMINATOR = 1_000_000_000;
    uint256 private constant MULTIPLIER = 10**20;

    // allocationSettings[settingId][expiry] = rewards portion of a pool for settingId
    mapping(uint256 => mapping(uint256 => uint256)) public allocationSettings;
    LatestSetting public latestSetting;

    mapping(uint256 => ExpiryData) internal expiryData;
    mapping(uint256 => EpochData) private epochData;
    mapping(address => UserExpiries) private userExpiries;

    modifier isFunded() {
        require(funded, "NOT_FUNDED");
        _;
    }

    constructor(
        address _governance,
        address _pendleTokenAddress,
        address _router, // The router basically identify our Pendle instance.
        bytes32 _marketFactoryId,
        bytes32 _forgeId,
        address _underlyingAsset,
        address _baseToken,
        uint256 _startTime,
        uint256 _epochDuration,
        uint256 _vestingEpochs
    ) Permissions(_governance) PendleLiquidityMiningNonReentrant() {
        require(_startTime > block.timestamp, "START_TIME_OVER");
        require(IERC20(_pendleTokenAddress).totalSupply() > 0, "INVALID_ERC20");
        require(IERC20(_underlyingAsset).totalSupply() > 0, "INVALID_ERC20");
        require(IERC20(_baseToken).totalSupply() > 0, "INVALID_ERC20");
        require(_vestingEpochs > 0, "INVALID_VESTING_EPOCHS");

        pendleTokenAddress = _pendleTokenAddress;
        router = IPendleRouter(_router);
        data = router.data();

        require(
            data.getMarketFactoryAddress(_marketFactoryId) != address(0),
            "INVALID_MARKET_FACTORY_ID"
        );
        require(data.getForgeAddress(_forgeId) != address(0), "INVALID_FORGE_ID");

        marketFactory = IPendleMarketFactory(data.getMarketFactoryAddress(_marketFactoryId));
        forge = data.getForgeAddress(_forgeId);
        marketFactoryId = _marketFactoryId;
        forgeId = _forgeId;
        underlyingAsset = _underlyingAsset;
        baseToken = _baseToken;
        startTime = _startTime;
        epochDuration = _epochDuration;
        vestingEpochs = _vestingEpochs;
    }

    function readUserExpiries(address _account)
        external
        view
        override
        returns (uint256[] memory _expiries)
    {
        _expiries = userExpiries[_account].expiries;
    }

    function balances(uint256 expiry, address user) external view override returns (uint256) {
        return expiryData[expiry].balances[user];
    }

    function lpHolderForExpiry(uint256 expiry) external view override returns (address) {
        return expiryData[expiry].lpHolder;
    }

    // fund a few epoches
    // One the last epoch is over, the program is permanently over and cannot be extended anymore
    function fund(uint256[] memory _rewards) external onlyGovernance {
        require(latestSetting.id > 0, "NO_ALLOC_SETTING");
        require(_getCurrentEpochId() <= numberOfEpochs, "LAST_EPOCH_OVER"); // we can only fund more if its still ongoing
        uint256 nNewEpoches = _rewards.length;

        uint256 totalFunded;
        for (uint256 i = 0; i < nNewEpoches; i++) {
            totalFunded = totalFunded.add(_rewards[i]);
            epochData[numberOfEpochs + i + 1].totalRewards = _rewards[i];
        }

        require(totalFunded > 0, "ZERO_FUND");
        funded = true;
        numberOfEpochs = numberOfEpochs.add(nNewEpoches);
        IERC20(pendleTokenAddress).safeTransferFrom(msg.sender, address(this), totalFunded);
    }

    /**
    @notice set a new allocation setting, which will be applied from the next Epoch onwards
    @dev  all the epochData from latestSetting.firstEpochToApply+1 to current epoch will follow the previous
    allocation setting
    @dev We must set the very first allocation setting before the start of epoch 1,
            otherwise epoch 1 will not have any allocation setting!
        In that case, we will not be able to set any allocation and hence its not possible to
            fund the contract as well
        => We should just throw this contract away, and funds are SAFU!
    @dev the length of _expiries array should be small, 2 or 3
     */
    function setAllocationSetting(
        uint256[] calldata _expiries,
        uint256[] calldata _allocationNumerators
    ) external onlyGovernance {
        require(_expiries.length == _allocationNumerators.length, "INVALID_ALLOCATION");
        if (latestSetting.id == 0) {
            require(block.timestamp < startTime, "LATE_FIRST_ALLOCATION");
        }

        uint256 curEpoch = _getCurrentEpochId();
        for (uint256 i = latestSetting.firstEpochToApply; i <= curEpoch; i++) {
            // save the epochSettingId for the epochData before the current epoch
            epochData[i].settingId = latestSetting.id;
        }
        latestSetting.firstEpochToApply = curEpoch + 1;
        latestSetting.id++;

        uint256 sumAllocationNumerators;
        for (uint256 _i = 0; _i < _expiries.length; _i++) {
            allocationSettings[latestSetting.id][_expiries[_i]] = _allocationNumerators[_i];
            sumAllocationNumerators = sumAllocationNumerators.add(_allocationNumerators[_i]);
        }
        require(sumAllocationNumerators == ALLOCATION_DENOMINATOR, "INVALID_ALLOCATION");
    }

    function stake(uint256 expiry, uint256 amount)
        external
        override
        isFunded
        nonReentrant
        returns (address newLpHoldingContractAddress)
    {
        ExpiryData storage exd = expiryData[expiry];
        uint256 curEpoch = _getCurrentEpochId();
        require(curEpoch > 0, "NOT_STARTED");
        require(curEpoch <= numberOfEpochs, "INCENTIVES_PERIOD_OVER");

        address xyt = address(data.xytTokens(forgeId, underlyingAsset, expiry));
        address marketAddress = data.getMarket(marketFactoryId, xyt, baseToken);
        require(xyt != address(0), "XYT_NOT_FOUND");
        require(marketAddress != address(0), "MARKET_NOT_FOUND");

        if (exd.lpHolder == address(0)) {
            newLpHoldingContractAddress = _addNewExpiry(expiry, xyt, marketAddress);
        }
        // if expiry doesn't exist yet, this function must still be called
        _settlePendingRewards(expiry, msg.sender);

        if (!userExpiries[msg.sender].hasExpiry[expiry]) {
            userExpiries[msg.sender].expiries.push(expiry);
            userExpiries[msg.sender].hasExpiry[expiry] = true;
        }
        // _pullLpToken must happens before totalStakeLPForExpiry and balances are updated
        _pullLpToken(marketAddress, expiry, amount);

        exd.balances[msg.sender] = exd.balances[msg.sender].add(amount);
        exd.totalStakeLP = exd.totalStakeLP.add(amount);
    }

    function withdraw(uint256 expiry, uint256 amount) external override nonReentrant isFunded {
        uint256 curEpoch = _getCurrentEpochId();
        require(curEpoch > 0, "NOT_STARTED");

        ExpiryData storage exd = expiryData[expiry];
        require(exd.balances[msg.sender] >= amount, "INSUFFICIENT_BALANCE");

        _settlePendingRewards(expiry, msg.sender);
        // _pushLpToken must happens before totalStakeLPForExpiry and balances are updated
        _pushLpToken(expiry, amount);

        exd.balances[msg.sender] = exd.balances[msg.sender].sub(amount);
        exd.totalStakeLP = exd.totalStakeLP.sub(amount);
    }

    function claimRewards()
        external
        override
        nonReentrant
        returns (uint256[] memory rewards, uint256 interests)
    {
        // claim PENDLE rewards
        uint256 curEpoch = _getCurrentEpochId(); //!!! what if currentEpoch > final epoch?
        require(curEpoch > 0, "NOT_STARTED");

        rewards = new uint256[](vestingEpochs);
        for (uint256 i = 0; i < userExpiries[msg.sender].expiries.length; i++) {
            uint256 expiry = userExpiries[msg.sender].expiries[i];
            rewards[0] = rewards[0].add(_settlePendingRewards(expiry, msg.sender));

            // claim LP interests
            interests = interests.add(_settleLpInterests(expiry, msg.sender));
        }

        for (uint256 i = 1; i < vestingEpochs; i++) {
            rewards[i] = rewards[i].add(
                epochData[curEpoch.add(i)].availableRewardsForUser[msg.sender]
            );
        }
    }

    function totalRewardsForEpoch(uint256 epochId)
        external
        view
        override
        returns (uint256 rewards)
    {
        rewards = epochData[epochId].totalRewards;
    }

    /**
    @notice update the following stake data for the current epoch:
        - epochData[current epoch].stakeUnitsForExpiry
        - epochData[current epoch].lastUpdatedForExpiry
    @dev If this is the very first transaction involving this expiry, then need to update for the
    previous epoch as well. If the previous didn't have any transactions at all, (and hence was not
    updated at all), we need to update it and check the previous previous ones, and so on..
    @dev must be called right before every _settlePendingRewards()
    @dev this is the only function that updates lastTimeUserStakeUpdated
    @dev other functions must make sure that totalStakeLPForExpiry could be assumed
        to stay exactly the same since lastTimeUserStakeUpdated until now;
     */
    function _updateStakeDataForExpiry(uint256 expiry) internal {
        uint256 _curEpoch = _getCurrentEpochId();

        // loop through all epochData in descending order
        for (uint256 i = Math.min(_curEpoch, numberOfEpochs); i > 0; i--) {
            uint256 epochEndTime = _endTimeOfEpoch(i);
            uint256 lastUpdatedForEpoch = epochData[i].lastUpdatedForExpiry[expiry];

            if (lastUpdatedForEpoch == epochEndTime) {
                break; // its already updated until this epoch, our job here is done
            }

            epochData[i].stakeUnitsForExpiry[expiry] = epochData[i].stakeUnitsForExpiry[expiry]
                .add(
                _calcUnitsStakeInEpoch(expiryData[expiry].totalStakeLP, lastUpdatedForEpoch, i)
            );
            epochData[i].lastUpdatedForExpiry[expiry] = Math.min(block.timestamp, epochEndTime);
        }
    }

    /**
    @notice Check if the user is entitled for any new rewards and transfer them to users.
        The rewards are calculated since the last time rewards was calculated for him,
        I.e. Since the last time his stake was "updated"
        I.e. Since lastTimeUserStakeUpdated[account]
    @dev The user's stake since lastTimeUserStakeUpdated[user] until now = balances[user][expiry]
    @dev After this function, the following should be updated correctly up to this point:
            - availableRewardsForEpoch[account][all epochData]
            - epochData[all epochData].stakeUnitsForUser
     */
    function _settlePendingRewards(uint256 expiry, address account)
        internal
        returns (uint256 _rewardsWithdrawableNow)
    {
        _updateStakeDataForExpiry(expiry);
        ExpiryData storage exd = expiryData[expiry];

        // account has not staked this LP_expiry before, no need to do anything
        if (exd.lastTimeUserStakeUpdated[account] == 0) {
            exd.lastTimeUserStakeUpdated[account] = block.timestamp;
            return 0;
        }

        uint256 _curEpoch = _getCurrentEpochId();
        uint256 _endEpoch = Math.min(numberOfEpochs, _curEpoch);

        // if _curEpoch<=numberOfEpochs
        // => the curEpoch hasn't ended yet
        // => the endEpoch hasn't ended yet (since endEpoch=curEpoch)
        bool _isEndEpochOver = (_curEpoch > numberOfEpochs);

        uint256 _startEpoch = _epochOfTimestamp(exd.lastTimeUserStakeUpdated[account]);

        /* Go through all epochs that are now over
        to update epochData[..].stakeUnitsForUser and epochData[..].availableRewardsForEpoch
        */
        for (uint256 epochId = _startEpoch; epochId <= _endEpoch; epochId++) {
            if (epochData[epochId].stakeUnitsForExpiry[expiry] == 0 && exd.totalStakeLP == 0) {
                /* in the extreme extreme case of zero staked LPs for this expiry even now,
                    => nothing to do from this epoch onwards */
                break;
            }

            epochData[epochId].stakeUnitsForUser[account][expiry] = epochData[epochId]
                .stakeUnitsForUser[account][expiry]
                .add(
                _calcUnitsStakeInEpoch(
                    exd.balances[account],
                    exd.lastTimeUserStakeUpdated[account],
                    epochId
                )
            );

            if (epochId == _endEpoch && !_isEndEpochOver) {
                break;
            }

            // this epoch has ended, users can claim rewards now

            // this should never happen
            assert(epochData[epochId].stakeUnitsForExpiry[expiry] != 0);

            RewardsData memory vars;
            vars.stakeUnitsForUser = epochData[epochId].stakeUnitsForUser[account][expiry];

            vars.settingId = epochId >= latestSetting.firstEpochToApply
                ? latestSetting.id
                : epochData[epochId].settingId;

            vars.rewardsForMarket = epochData[epochId]
                .totalRewards
                .mul(allocationSettings[vars.settingId][expiry])
                .div(ALLOCATION_DENOMINATOR);

            vars.rewardsPerVestingEpoch = vars
                .rewardsForMarket
                .mul(vars.stakeUnitsForUser)
                .div(epochData[epochId].stakeUnitsForExpiry[expiry])
                .div(vestingEpochs);

            // Now we distribute this rewards over the vestingEpochs starting from epochId + 1
            // to epochId + vestingEpochs
            for (uint256 i = epochId + 1; i <= epochId + vestingEpochs; i++) {
                epochData[i].availableRewardsForUser[account] = epochData[i]
                    .availableRewardsForUser[account]
                    .add(vars.rewardsPerVestingEpoch);
            }
        }

        exd.lastTimeUserStakeUpdated[account] = block.timestamp;
        _rewardsWithdrawableNow = _pushRewardsWithdrawableNow(account);
    }

    /**
     * @dev the loop starts from 2 because 2 is the earliest epoch that users can claim rewards
     */
    function _pushRewardsWithdrawableNow(address _account)
        internal
        returns (uint256 rewardsWithdrawableNow)
    {
        uint256 _curEpoch = _getCurrentEpochId();
        for (uint256 i = 2; i <= _curEpoch; i++) {
            if (epochData[i].availableRewardsForUser[_account] > 0) {
                rewardsWithdrawableNow = rewardsWithdrawableNow.add(
                    epochData[i].availableRewardsForUser[_account]
                );
                epochData[i].availableRewardsForUser[_account] = 0;
            }
        }
        if (rewardsWithdrawableNow != 0) {
            IERC20(pendleTokenAddress).safeTransfer(_account, rewardsWithdrawableNow);
        }
    }

    /**
     * @notice retuns the stakeUnits in the _epochId(th) epoch of an user if he stake from _startTime to now
     * @dev to calculate durationStakeThisEpoch:
     *   user will stake from _startTime -> _endTime, while the epoch last from _startTimeOfEpoch -> _endTimeOfEpoch
     *   => the stakeDuration of user will be min(_endTime,_endTimeOfEpoch) - max(_startTime,_startTimeOfEpoch)
     */
    function _calcUnitsStakeInEpoch(
        uint256 lpAmount,
        uint256 _startTime,
        uint256 _epochId
    ) internal view returns (uint256 stakeUnitsForUser) {
        uint256 _endTime = block.timestamp;

        uint256 _l = Math.max(_startTime, _startTimeOfEpoch(_epochId));
        uint256 _r = Math.min(_endTime, _endTimeOfEpoch(_epochId));
        uint256 durationStakeThisEpoch = (_l >= _r ? 0 : _r - _l);

        return lpAmount.mul(durationStakeThisEpoch);
    }

    function _pullLpToken(
        address marketAddress,
        uint256 expiry,
        uint256 amount
    ) internal {
        _settleLpInterests(expiry, msg.sender);
        IERC20(marketAddress).safeTransferFrom(msg.sender, expiryData[expiry].lpHolder, amount);
    }

    function _pushLpToken(uint256 expiry, uint256 amount) internal {
        _settleLpInterests(expiry, msg.sender);
        IPendleLpHolder(expiryData[expiry].lpHolder).sendLp(msg.sender, amount);
    }

    function _settleLpInterests(uint256 expiry, address account)
        internal
        returns (uint256 dueInterests)
    {
        if (account == address(this)) return 0;

        ExpiryData storage exd = expiryData[expiry];
        // even if exd.balances[account]==0, this function must still be called
        // if (exd.balances[account] == 0) return 0;

        _updateParamL(expiry);

        uint256 interestValuePerLP = _getInterestValuePerLP(expiry, account);
        if (interestValuePerLP == 0) return 0;

        dueInterests = exd.balances[account].mul(interestValuePerLP).div(MULTIPLIER);
        if (dueInterests == 0) return 0;

        exd.lastNYield = exd.lastNYield.sub(dueInterests);
        IPendleLpHolder(exd.lpHolder).sendInterests(account, dueInterests);
    }

    function checkNeedUpdateParamL(uint256 expiry) internal returns (bool) {
        if (expiryData[expiry].totalStakeLP == 0) {
            return false;
        }
        if (_getIncomeIndexIncreaseRate(expiry) > data.interestUpdateRateDeltaForMarket()) {
            return true;
        }
        return false;
    }

    function _updateParamL(uint256 expiry) internal {
        ExpiryData storage exd = expiryData[expiry];
        require(exd.lpHolder != address(0), "INVALID_EXPIRY");

        if (!checkNeedUpdateParamL(expiry)) {
            return;
        }

        IPendleLpHolder(exd.lpHolder).claimLpInterests();
        // calculate interest related params

        IERC20 underlyingYieldToken =
            IERC20(
                IPendleYieldToken(data.xytTokens(forgeId, underlyingAsset, expiry))
                    .underlyingYieldToken()
            );

        uint256 currentNYield = underlyingYieldToken.balanceOf(exd.lpHolder);
        (uint256 firstTerm, uint256 paramR) = _getFirstTermAndParamR(expiry, currentNYield);

        // exd.totalStakeLP has been checked to be != 0
        uint256 secondTerm = paramR.mul(MULTIPLIER).div(exd.totalStakeLP);

        // Update new states
        exd.paramL = firstTerm.add(secondTerm);
        exd.lastNYield = currentNYield;
    }

    function _addNewExpiry(
        uint256 expiry,
        address xyt,
        address marketAddress
    ) internal returns (address newLpHoldingContractAddress) {
        allExpiries.push(expiry);
        address underlyingYieldToken = IPendleYieldToken(xyt).underlyingYieldToken();
        newLpHoldingContractAddress = Factory.createContract(
            type(PendleLpHolder).creationCode,
            abi.encodePacked(marketAddress, marketFactory.router(), underlyingYieldToken),
            abi.encode(marketAddress, marketFactory.router(), underlyingYieldToken)
        );
        expiryData[expiry].lpHolder = newLpHoldingContractAddress;
        _afterAddingNewExpiry(expiry);
    }

    function _getData() internal view override returns (IPendleData) {
        return data;
    }

    // 1-indexed
    function _getCurrentEpochId() internal view returns (uint256) {
        return _epochOfTimestamp(block.timestamp);
    }

    function _epochOfTimestamp(uint256 t) internal view returns (uint256) {
        if (t < startTime) return 0;
        return t.sub(startTime).div(epochDuration).add(1);
    }

    function _startTimeOfEpoch(uint256 t) internal view returns (uint256) {
        // epoch id starting from 1
        return startTime + (t - 1) * epochDuration;
    }

    function _endTimeOfEpoch(uint256 t) internal view returns (uint256) {
        // epoch id starting from 1
        return startTime + (t) * epochDuration;
    }

    function _getInterestValuePerLP(uint256 expiry, address account)
        internal
        virtual
        returns (uint256 interestValuePerLP);

    function _getFirstTermAndParamR(uint256 expiry, uint256 currentNYield)
        internal
        virtual
        returns (uint256 firstTerm, uint256 paramR);

    function _afterAddingNewExpiry(uint256 expiry) internal virtual;

    function _getIncomeIndexIncreaseRate(uint256 expiry)
        internal
        virtual
        returns (uint256 increaseRate);
}
