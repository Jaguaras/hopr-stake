// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
// import "@openzeppelin/contracts/utils/Arrays.sol";
// import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IHoprBoost.sol";

/**
 * 
 */
contract HoprStake is Ownable, IERC777Recipient, IERC721Receiver, ReentrancyGuard { // is IERC777Recipient, IERC721Receiver, 
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Account {
        uint256 actualLockedTokenAmount; // The amount of LOCK_TOKEN being actually locked to the contract. 
                                         // Those tokens can be withdrawn after “UNLOCK_START”
        uint256 virtualLockedTokenAmount; // The amount of LOCK_TOKEN token being virtually locked to the contract. 
                                          // This field is only relevant to seed investors. Those tokens cannot be withdrawn after “UNLOCK_START”.
        uint256 lastSyncTimestamp; // Timestamp at which any “Account” attribute gets synced for the last time. 
        uint256 cumulatedRewards; // Rewards accredited to the account at “lastSyncTimestamp”.
        uint256 claimedRewards; // Rewards claimed by the account.
    }

    uint256 public constant LOCK_DEADLINE = 1627387200; // Block timestamp at which incentive program starts. It is thus the deadline for locking tokens. Default value is 1627387200 (July 27th 2021 14:00 CET).
    uint256 public constant UNLOCK_START = 1642424400; // Block timestamp at which incentive program ends. From this timestamp on, tokens can be unlocked. Default value is 1642424400 (Jan 17th 2022 14:00 CET).
    uint256 public constant FACTOR_DENOMINATOR = 1e12; // Denominator of the “Basic reward factor”. Default value is 1e12.
    uint256 public constant FACTOR_NUMERATOR = 5787; // Numerator of the “Basic reward factor”, for all accounts (except for seed investors) that participate in the program. Default value is 5787, which corresponds to 5.787/1e9 per second. Its associated denominator is FACTOR_DENOMINATOR. 
    address public constant LOCK_TOKEN = 0xD057604A14982FE8D88c5fC25Aac3267eA142a08; // Token that HOPR holders need to lock to the contract: xHOPR address.
    address public constant REWARD_TOKEN = 0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1; // Token that HOPR holders can claim as rewards: wxHOPR address

    IHoprBoost public nftContract; // Address of the NFT smart contract.
    mapping(address=>mapping(uint256=>uint256)) public redeemedFactor; // Redeemed additional boost factors per account, structured as “account -> index -> NFT tokenId”.
    mapping(address=>uint256) public redeemedFactorIndex; // The last index of redeemed boost factor of an account. It defines the length of the “redeemed factor” mapping.
    mapping(address=>Account) public accounts; // It stores the locked token amount, earned and claimed rewards per account.
    uint256 public totalLocked;  // Total amount of tokens being locked in the incentive program. Virtual token locks are not taken into account.
    uint256 public availableReward; // Total amount of reward tokens currently available in the lock.

    // setup ERC1820
    IERC1820Registry private constant ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    event Sync(address indexed account, uint256 indexed increment);
    event Stake(address indexed account, uint256 indexed actualAmount, uint256 indexed virtualAmount);
    event RewardFueled(uint256 indexed amount);
    event Redeemed(address indexed account, uint256 indexed boostTokenId);
    event Claimed(address indexed account, uint256 indexed rewardAmount);

    /**
     * @dev Provide NFT contract address. Transfer owner role to the new owner address. 
     * At deployment, it also registers the lock contract as an ERC777 recipient. 
     * @param _nftAddress address Address of the NFT contract.
     * @param _newOwner address Address of the new owner. This new owner can reclaim any ERC20 and ERC721 token being accidentally sent to the lock contract. 
     */
    constructor(address _nftAddress, address _newOwner) {
        nftContract = IHoprBoost(_nftAddress);
        transferOwnership(_newOwner);
        ERC1820_REGISTRY.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    /**
     * @dev ERC677 hook. Token holders can send their tokens with `transferAndCall` to the stake contract. 
     * Before LOCK_DEADLINE, it accepts tokens, update “Account” in accounts mapping, 
     * Update totalLocked and mint precrafted boosts (calling onIntialLock() of “HoprBoost NFT contract”); 
     * After UNLOCK_START, it refuses tokens; In between, it’s only possible to accept tokens from existing accounts.
     * and update totalLocked, sync Account state. 
     * @param _from address Address of tokens sender
     * @param _value uint256 token amount being transferred
     * @param _data bytes Data being sent along with token transfer
     */
    function onTokenTransfer(
        address _from, 
        uint256 _value, 
        // solhint-disable-next-line no-unused-vars
        bytes memory _data
    ) external returns (bool) {
        require(msg.sender == LOCK_TOKEN, "HoprStake: Only accept LOCK_TOKEN in staking");
        require(block.timestamp <= UNLOCK_START, "HoprStake: Program ended, cannot stake anymore.");
        Account memory account = accounts[_from];

        if (block.timestamp > LOCK_DEADLINE) {
            require(account.actualLockedTokenAmount + account.virtualLockedTokenAmount > 0, "HoprStake: Program started, too late to put initial stake.");
            _sync(_from);
        }

        accounts[_from].actualLockedTokenAmount += _value;
        accounts[_from].lastSyncTimestamp = block.timestamp;
        totalLocked += _value;
        emit Stake(_from, accounts[_from].actualLockedTokenAmount, accounts[_from].virtualLockedTokenAmount);

        if (block.timestamp <= LOCK_DEADLINE) {
            nftContract.onInitialLock(_from);
        }
        return true;
    }

    /**
     * @dev ERC777 hook. To receive wxHOPR to fuel the reward pool with `send()` method. It updates the availableReward by tokenAmount.
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes hex information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     */
    function tokensReceived(
        // solhint-disable-next-line no-unused-vars
        address operator,
        address from,
        address to,
        uint256 amount,
        // solhint-disable-next-line no-unused-vars
        bytes calldata userData,
        // solhint-disable-next-line no-unused-vars
        bytes calldata operatorData
    ) external override nonReentrant {
        require(msg.sender == REWARD_TOKEN, "HoprStake: Sender must be wxHOPR token");
        require(to == address(this), "HoprStake: Must be sending tokens to HOPR Stake contract");
        require(from == owner(), "HoprStake: Only accept owner to provide rewards");
        availableReward += amount;
        emit RewardFueled(amount);
    }

    /**
     * @dev Whenever a boost `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * when redeeming, this function is called. 
     * It must return its Solidity selector to confirm the token transfer upon success.
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param tokenId uint256 amount of tokens to transfer
     * @param data bytes hex information provided by the token holder (if any)
     */
    function onERC721Received(
        // solhint-disable-next-line no-unused-vars
        address operator,
        address from,
        uint256 tokenId,
        // solhint-disable-next-line no-unused-vars
        bytes calldata data
    ) external override returns (bytes4) {
        require(_msgSender() == address(nftContract), "HoprStake: Cannot SafeTransferFrom tokens other than HoprBoost.");
        require(block.timestamp <= UNLOCK_START, "HoprStake: Program ended, cannot redeem boosts.");
        // redeem NFT
        Account memory account = accounts[from];
        require(account.actualLockedTokenAmount + account.virtualLockedTokenAmount > 0, "HoprStake: Cannot redeem for account with nothing at stake.");
        _sync(from);
        redeemedFactor[from][redeemedFactorIndex[from]] = tokenId;
        redeemedFactorIndex[from] += 1;
        // burns token after redeeming
        nftContract.burn(tokenId);
        emit Redeemed(from, tokenId);
        return IERC721Receiver(address(this)).onERC721Received.selector;
    }

    /**
    * @dev Only owner can call this function before program starts to store virtual lock for seed investors. 
    * If the investor hasn't locked any token in this account, create an "Account" with {0, caps[i], block.timestamp, 0, 0}. 
    * If the investor has locked some tokens in this account, update its “virtualLockedTokenAmount”.
    * @param investors address[] Array of seed investors accounts.
    * @param caps uint256[] Array of their virtually locked tokens.
    */
    function lock(address[] calldata investors, uint256[] calldata caps) onlyOwner external {
        require(block.timestamp <= LOCK_DEADLINE, "HoprStake: Program ended, cannot stake anymore.");
        require(investors.length <= caps.length, "HoprStake: Length does not match");

        for (uint256 index = 0; index < investors.length; index++) { 
            address investor = investors[index];
            Account memory account = accounts[investor];

            accounts[investor].virtualLockedTokenAmount += caps[index];
            accounts[investor].lastSyncTimestamp = block.timestamp;

            nftContract.onInitialLock(investor);
            emit Stake(investor, account.actualLockedTokenAmount, accounts[investor].virtualLockedTokenAmount);
        }
    }

    /**
     * @dev Manually sync account's reward states
     * @notice public function of ``_sync``.
     * @param account address Account whose stake rewards will be synced.
     */
    function sync(address account) external {
        _sync(account); 
    }

    /**
     * @dev Sync rewards and claim them
     * @notice public function of ``_sync`` + ``_claim``
     * @param account address Account whose stake rewards will be synced and claimed.
     */
    function claimRewards(address account) public {
        _sync(account); 
        _claim(account);
    }

    /**
     * @dev Unlock staking
     * @param account address Account that staked tokens.
     */
    function unlock(address account) external {
        require(block.timestamp > UNLOCK_START, "HoprStake: Program is ongoing, cannot unlock stake.");
        uint256 stake = accounts[account].actualLockedTokenAmount;
        _sync(account); 
        accounts[account].actualLockedTokenAmount = 0;
        totalLocked -= stake;
        _claim(account);
        // unlock tokens
        IERC20(LOCK_TOKEN).safeTransfer(account, stake);
    }

    /**
     * @dev Reclaim any ERC20 token being accidentally sent to the contract.
     * @param tokenAddress address ERC20 token address.
     */
    function reclaimErc20Tokens(address tokenAddress) external onlyOwner {
        uint256 difference;
        if (tokenAddress == LOCK_TOKEN) {
            difference = IERC20(LOCK_TOKEN).balanceOf(address(this)) - totalLocked;
        } else {
            difference = IERC20(tokenAddress).balanceOf(address(this));
        }
        IERC20(tokenAddress).safeTransfer(owner(), difference);
    }

    /**
     * @dev Reclaim any ERC721 token being accidentally sent to the contract.
     * @param tokenAddress address ERC721 token address.
     */
    function reclaimErc721Tokens(address tokenAddress, uint256 tokenId) external onlyOwner {
        IHoprBoost(tokenAddress).transferFrom(address(this), owner(), tokenId);
    }

    /**
     * @dev Returns the increment of cumulated rewards during the “lastSyncTimestamp” and current block.timestamp. 
     * @param _account address Address of the account whose rewards will be calculated.
     */
    function getCumulatedRewardsIncrement(address _account) public view returns (uint256) {
        return _getCumulatedRewardsIncrement(_account);
    }

    /**
     * @dev Calculates the increment of cumulated rewards during the “lastSyncTimestamp” and block.timestamp. 
     * @param _account address Address of the account whose rewards will be calculated.
     */
    function _getCumulatedRewardsIncrement(address _account) private view returns (uint256) {
        if (block.timestamp < LOCK_DEADLINE) {
            return 0;
        }

        Account memory account = accounts[_account];
        uint256 nominalTokenAmount = account.actualLockedTokenAmount + account.virtualLockedTokenAmount;
        uint256 incrementNumerator = nominalTokenAmount * FACTOR_NUMERATOR;

        for (uint256 index = 0; index < redeemedFactorIndex[_account]; index++) {
            uint256 tokenId = redeemedFactor[_account][index];
            uint256 boost = nftContract.boostFactorOf(tokenId);
            incrementNumerator += (nominalTokenAmount) * boost;
        }
        return incrementNumerator * (block.timestamp.min(UNLOCK_START) - (account.lastSyncTimestamp.max(LOCK_DEADLINE)).min(UNLOCK_START)) / FACTOR_DENOMINATOR;
    }

    /**
     * @dev Update “lastSyncTimestamp” with the current block timestamp and update “cumulatedRewards” with _getCumulatedRewardsIncrement(account) 
     * @param _account address Address of the account whose rewards will be calculated.
     */
    function _sync(address _account) private {
        uint256 increment = _getCumulatedRewardsIncrement(_account);
        accounts[_account].cumulatedRewards += increment;
        accounts[_account].lastSyncTimestamp = block.timestamp;
        emit Sync(_account, increment);
    }

    /**
     * @dev Claim rewards for staking.
     * @param _account address Address of the staking account.
     */
    function _claim(address _account) private {
        Account memory account = accounts[_account];
        // update states
        uint256 amount = account.cumulatedRewards - account.claimedRewards;
        require(amount > 0, "HoprStake: Nothing to claim");
        accounts[_account].claimedRewards = accounts[_account].cumulatedRewards;
        require(availableReward >= amount, "HoprStake: Insufficient reward pool.");
        availableReward -= amount;
        // send rewards to the account.
        emit Claimed(_account, amount);
        IERC20(REWARD_TOKEN).safeTransfer(_account, amount);
    }
}