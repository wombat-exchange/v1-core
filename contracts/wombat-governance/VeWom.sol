// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './libraries/DSMath.sol';
import './libraries/LogExpMath.sol';
import './interfaces/IWhitelist.sol';
import './interfaces/IMasterWombat.sol';
import './interfaces/IVeWom.sol';
import './VeERC20Upgradeable.sol';

interface IVe {
    function vote(address user, int256 voteDelta) external;
}

/// @title VeWom
/// @notice Wombat Waddle: the staking contract for WOM, as well as the token used for governance.
/// Note Waddling does not seem to slow the Wombat, it only makes it sturdier.
/// Note that it's ownable and the owner wields tremendous power. The ownership
/// will be transferred to a governance smart contract once Wombat is sufficiently
/// distributed and the community can show to govern itself.
contract VeWom is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    VeERC20Upgradeable,
    IVeWom,
    IVe
{
    using SafeERC20 for IERC20;
    using DSMath for uint256;

    uint256 constant WAD = 1e18;

    /// @notice the wom token
    IERC20 public wom;

    /// @notice the masterWombat contract
    IMasterWombat public masterWombat;

    /// @notice whitelist wallet checker
    /// @dev contract addresses are by default unable to stake wom, they must be previously whitelisted to stake wom
    IWhitelist public whitelist;

    uint32 maxBreedingLength;
    uint32 minLockDays;
    uint32 maxLockDays;

    /// @notice user info mapping
    mapping(address => UserInfo) internal users;

    /// @notice Address of the Voter contract
    address public voter;
    /// @notice amount of vote used currently for each user
    mapping(address => uint256) public usedVote;

    event Enter(address addr, uint256 unlockTime, uint256 womAmount, uint256 veWomAmount);
    event Exit(address addr, uint256 unlockTime, uint256 womAmount, uint256 veWomAmount);
    event SetMasterWombat(address addr);
    event SetVoter(address addr);
    event SetWhiteList(address addr);
    event SetMaxBreedingLength(uint256 len);
    event UpdateLockTime(
        address addr,
        uint256 slot,
        uint256 unlockTime,
        uint256 womAmount,
        uint256 originalVeWomAmount,
        uint256 newVeWomAmount
    );

    error VEWOM_OVERFLOW();

    modifier onlyVoter() {
        require(msg.sender == voter, 'VeWom: caller is not voter');
        _;
    }

    function initialize(IERC20 _wom, IMasterWombat _masterWombat) external initializer {
        require(address(_masterWombat) != address(0), 'zero address');
        require(address(_wom) != address(0), 'zero address');

        // Initialize veWOM
        __ERC20_init('Wombat Waddle', 'veWOM');
        __Ownable_init();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();

        masterWombat = _masterWombat;
        wom = _wom;

        // Note: one should pay attention to storage collision
        maxBreedingLength = 10000;
        minLockDays = 7;
        maxLockDays = 1461;
    }

    function _verifyVoteIsEnough(address _user) internal view {
        require(balanceOf(_user) >= usedVote[_user], 'VeWom: not enough vote');
    }

    /**
     * @dev pause pool, restricting certain operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev unpause pool, enabling certain operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice sets masterWombat address
    /// @param _masterWombat the new masterWombat address
    function setMasterWombat(IMasterWombat _masterWombat) external onlyOwner {
        require(address(_masterWombat) != address(0), 'zero address');
        masterWombat = _masterWombat;
        emit SetMasterWombat(address(_masterWombat));
    }

    /// @notice sets voter contract address
    /// @param _voter the new NFT contract address
    function setVoter(address _voter) external onlyOwner {
        require(address(_voter) != address(0), 'zero address');
        voter = _voter;
        emit SetVoter(_voter);
    }

    /// @notice sets whitelist address
    /// @param _whitelist the new whitelist address
    function setWhitelist(IWhitelist _whitelist) external onlyOwner {
        require(address(_whitelist) != address(0), 'zero address');
        whitelist = _whitelist;
        emit SetWhiteList(address(_whitelist));
    }

    function setMaxBreedingLength(uint256 _maxBreedingLength) external onlyOwner {
        if (_maxBreedingLength > type(uint32).max) revert VEWOM_OVERFLOW();
        maxBreedingLength = uint32(_maxBreedingLength);
        emit SetMaxBreedingLength(_maxBreedingLength);
    }

    /// @notice checks wether user _addr has wom staked
    /// @param _addr the user address to check
    /// @return true if the user has wom in stake, false otherwise
    function isUser(address _addr) external view override returns (bool) {
        return balanceOf(_addr) > 0;
    }

    /// @notice return the amount of Wom locked and veWOM acquired by a user
    function getUserOverview(address _addr) external view override returns (uint256 womLocked, uint256 veWomBalance) {
        UserInfo storage user = users[_addr];
        uint256 len = user.breedings.length;
        for (uint256 i = 0; i < len; i++) {
            womLocked += user.breedings[i].womAmount;
        }
        veWomBalance = balanceOf(_addr);
    }

    /// @notice return the user info
    function getUserInfo(address addr) external view override returns (UserInfo memory) {
        return users[addr];
    }

    /// @dev explicity override multiple inheritance
    function totalSupply() public view override(VeERC20Upgradeable, IVeWom) returns (uint256) {
        return super.totalSupply();
    }

    /// @dev explicity override multiple inheritance
    function balanceOf(address account) public view override(VeERC20Upgradeable, IVeWom) returns (uint256) {
        return super.balanceOf(account);
    }

    function _expectedVeWomAmount(uint256 amount, uint256 lockDays) internal pure returns (uint256) {
        // veWOM = WOM * 0.026 * lockDays^0.5
        return amount.wmul(26162237992630200).wmul(LogExpMath.pow(lockDays * WAD, 50e16));
    }

    /// @notice lock WOM into contract and mint veWOM
    function mint(
        uint256 amount,
        uint256 lockDays
    ) external virtual override nonReentrant whenNotPaused returns (uint256 veWomAmount) {
        require(amount > 0, 'amount to deposit cannot be zero');
        if (amount > uint256(type(uint104).max)) revert VEWOM_OVERFLOW();

        // assert call is not coming from a smart contract
        // unless it is whitelisted
        _assertNotContract(msg.sender);

        require(lockDays >= uint256(minLockDays) && lockDays <= uint256(maxLockDays), 'lock days is invalid');
        require(users[msg.sender].breedings.length < uint256(maxBreedingLength), 'breed too much');

        uint256 unlockTime = block.timestamp + 86400 * lockDays; // seconds in a day = 86400
        veWomAmount = _expectedVeWomAmount(amount, lockDays);

        if (unlockTime > uint256(type(uint48).max)) revert VEWOM_OVERFLOW();
        if (veWomAmount > uint256(type(uint104).max)) revert VEWOM_OVERFLOW();

        users[msg.sender].breedings.push(Breeding(uint48(unlockTime), uint104(amount), uint104(veWomAmount)));

        // Request Wom from user
        wom.safeTransferFrom(msg.sender, address(this), amount);

        // event Mint(address indexed user, uint256 indexed amount) is emitted
        _mint(msg.sender, veWomAmount);

        emit Enter(msg.sender, unlockTime, amount, veWomAmount);
    }

    function burn(uint256 slot) external override nonReentrant whenNotPaused {
        uint256 length = users[msg.sender].breedings.length;
        require(slot < length, 'wut?');

        Breeding memory breeding = users[msg.sender].breedings[slot];
        require(uint256(breeding.unlockTime) <= block.timestamp, 'not yet meh');

        // remove slot
        if (slot != length - 1) {
            users[msg.sender].breedings[slot] = users[msg.sender].breedings[length - 1];
        }
        users[msg.sender].breedings.pop();

        wom.transfer(msg.sender, breeding.womAmount);

        // event Burn(address indexed user, uint256 indexed amount) is emitted
        _burn(msg.sender, breeding.veWomAmount);

        emit Exit(msg.sender, breeding.unlockTime, breeding.womAmount, breeding.veWomAmount);
    }

    /// @notice update the WOM lock days such that the end date is `now` + `lockDays`
    /// @param slot the veWOM slot
    /// @param lockDays the new lock days (it should be larger than original lock days)
    function update(
        uint256 slot,
        uint256 lockDays
    ) external override nonReentrant whenNotPaused returns (uint256 newVeWomAmount) {
        _assertNotContract(msg.sender);

        require(lockDays >= uint256(minLockDays) && lockDays <= uint256(maxLockDays), 'lock days is invalid');

        uint256 length = users[msg.sender].breedings.length;
        require(slot < length, 'slot position should be less than the number of slots');

        uint256 originalUnlockTime = uint256(users[msg.sender].breedings[slot].unlockTime);
        uint256 originalWomAmount = uint256(users[msg.sender].breedings[slot].womAmount);
        uint256 originalVeWomAmount = uint256(users[msg.sender].breedings[slot].veWomAmount);
        uint256 newUnlockTime = block.timestamp + 1 days * lockDays;
        newVeWomAmount = _expectedVeWomAmount(originalWomAmount, lockDays);

        if (newUnlockTime > type(uint48).max) revert VEWOM_OVERFLOW();
        if (newVeWomAmount > type(uint104).max) revert VEWOM_OVERFLOW();

        require(originalUnlockTime < newUnlockTime, 'the new end date must be greater than existing end date');
        require(
            originalVeWomAmount < newVeWomAmount,
            'the new veWom amount must be greater than existing veWom amount'
        );

        // change unlock time and veWom amount
        users[msg.sender].breedings[slot].unlockTime = uint48(newUnlockTime);
        users[msg.sender].breedings[slot].veWomAmount = uint104(newVeWomAmount);

        _mint(msg.sender, newVeWomAmount - originalVeWomAmount);

        // emit event
        emit UpdateLockTime(msg.sender, slot, newUnlockTime, originalWomAmount, originalVeWomAmount, newVeWomAmount);
    }

    /// @notice asserts addres in param is not a smart contract.
    /// @notice if it is a smart contract, check that it is whitelisted
    /// @param _addr the address to check
    function _assertNotContract(address _addr) private view {
        if (_addr != tx.origin) {
            require(
                address(whitelist) != address(0) && whitelist.check(_addr),
                'Smart contract depositors not allowed'
            );
        }
    }

    /// @notice hook called after token operation mint/burn
    /// @dev updates masterWombat
    /// @param _account the account being affected
    /// @param _newBalance the newVeWomBalance of the user
    function _afterTokenOperation(address _account, uint256 _newBalance) internal override {
        _verifyVoteIsEnough(_account);
        masterWombat.updateFactor(_account, _newBalance);
    }

    function vote(address _user, int256 _voteDelta) external override onlyVoter {
        if (_voteDelta >= 0) {
            usedVote[_user] += uint256(_voteDelta);
            _verifyVoteIsEnough(_user);
        } else {
            // reverts if usedVote[_user] < -_voteDelta
            usedVote[_user] -= uint256(-_voteDelta);
        }
    }
}
