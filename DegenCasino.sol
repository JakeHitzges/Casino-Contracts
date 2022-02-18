// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPlayer {
    function ownerOf(uint id) external view returns (address);
    function isLoanShark(uint16 id) external view returns (bool);
    function transferFrom(address from, address to, uint tokenId) external;
    function safeTransferFrom(address from, address to, uint tokenId, bytes memory _data) external;
}

interface IChips {
    function mint(address account, uint amount) external;
}

contract DegenCasino is Ownable, IERC721Receiver {
    
    //boolean to turn off/on bust protocol
    bool bust = false;
    //boolean, time variable and constant uint to turn off if a burn has occured today and on if one has not, so possability for only 1 burn to occur each day.
    bool private alreadyBurnt = false;
    uint constant private secondsPerDay = 86400;
    uint private sinceBurn = 0;
    //boolean to turn of one burn per day
    bool checkForBurnOn = false;
    //address allowed to turn off/on bust protocol. 
    address bustMan = 0x015F3adAe1CEC8C509Dea2CAd7348a5eF4F9AAF0;
    //burn wallet address. 
    address addrB = 0x015F3adAe1CEC8C509Dea2CAd7348a5eF4F9AAF0;
    address payable burnWall = payable(addrB);

    bool private _paused = false;

    uint16 private _randomIndex = 0;
    uint private _randomCalls = 0;
    mapping(uint => address) private _randomSource;

    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address owner, uint16 tokenId, uint value);
    event ChipPlayerClaimed(uint16 tokenId, uint earned, bool unstaked);
    event LoanSharkClaimed(uint16 tokenId, uint earned, bool unstaked);

    IPlayer public player;
    IChips public chip;

    mapping(uint256 => uint256) public chipPlayerIndices;
    mapping(address => Stake[]) public chipPlayerStake;

    mapping(uint256 => uint256) public loanSharkIndices;
    mapping(address => Stake[]) public loanSharkStake;
    address[] public loanSharkHolders;

    // Total staked tokens
    uint public totalChipPlayerStaked;
    uint public totalLoanSharkStaked = 0;
    uint public unaccountedRewards = 0;

    // ChipPlayer earn 10000 $CHIPS per day
    uint public constant DAILY_CHIP_RATE = 10000 ether;
    //changed this from 2 days to 1 so that 1% burn a day would occur as requested.
    uint public constant MINIMUM_TIME_TO_EXIT = 1 days;
    uint public constant TAX_PERCENTAGE = 20;
    uint public constant MAXIMUM_GLOBAL_CHIP = 2400000000 ether;

    uint public totalChipEarned;

    uint public lastClaimTimestamp;
    uint public loanSharkReward = 0;

    // emergency rescue to allow unstaking without any checks but without $CHIPS
    bool public rescueEnabled = false;

    constructor() {
        // Fill random source addresses
        _randomSource[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        _randomSource[1] = 0x3cD751E6b0078Be393132286c442345e5DC49699;
        _randomSource[2] = 0xb5d85CBf7cB3EE0D56b3bB207D5Fc4B82f43F511;
        _randomSource[3] = 0xC098B2a3Aa256D2140208C3de6543aAEf5cd3A94;
        _randomSource[4] = 0x28C6c06298d514Db089934071355E5743bf21d60;
        _randomSource[5] = 0x2FAF487A4414Fe77e2327F0bf4AE2a264a776AD2;
        _randomSource[6] = 0x267be1C1D684F78cb4F6a176C4911b741E4Ffdc0;
    }

    function paused() public view virtual returns (bool) {
        return _paused;
    }

    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    function setPlayer(address _player) external onlyOwner {
        player = IPlayer(_player);
    }

    function setChip(address _chip) external onlyOwner {
        chip = IChips(_chip);
    }

    function getAccountChipPlayers(address user) external view returns (Stake[] memory) {
        return chipPlayerStake[user];
    }

    function getAccountLoanSharks(address user) external view returns (Stake[] memory) {
        return loanSharkStake[user];
    }

    function addTokensToStake(address account, uint16[] calldata tokenIds) external {
        require(account == msg.sender || msg.sender == address(player), "You do not have a permission to do that");

        for (uint i = 0; i < tokenIds.length; i++) {
            if (msg.sender != address(player)) {
                // dont do this step if its a mint + stake
                require(player.ownerOf(tokenIds[i]) == msg.sender, "This NTF does not belong to address");
                player.transferFrom(msg.sender, address(this), tokenIds[i]);
            } else if (tokenIds[i] == 0) {
                continue; // there may be gaps in the array for stolen tokens
            }

            if (player.isLoanShark(tokenIds[i])) {
                _stakeLoanSharks(account, tokenIds[i]);
            } else {
                _stakeChipPlayers(account, tokenIds[i]);
            }
        }
    }

    function _stakeChipPlayers(address account, uint16 tokenId) internal whenNotPaused _updateEarnings {
        totalChipPlayerStaked += 1;

        chipPlayerIndices[tokenId] = chipPlayerStake[account].length;
        chipPlayerStake[account].push(Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        }));
        emit TokenStaked(account, tokenId, block.timestamp);
    }


    function _stakeLoanSharks(address account, uint16 tokenId) internal {
        totalLoanSharkStaked += 1;

        // If account already has some loanSharks no need to push it to the tracker
        if (loanSharkStake[account].length == 0) {
            loanSharkHolders.push(account);
        }

        loanSharkIndices[tokenId] = loanSharkStake[account].length;
        loanSharkStake[account].push(Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(loanSharkReward)
            }));

        emit TokenStaked(account, tokenId, loanSharkReward);
    }


    function claimFromStake(uint16[] calldata tokenIds, bool unstake) external whenNotPaused _updateEarnings {
        uint owed = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            if (!player.isLoanShark(tokenIds[i])) {
                owed += _claimFromPlayer(tokenIds[i], unstake);
            } else {
                owed += _claimFromLoanShark(tokenIds[i], unstake);
            }
        }
        if (owed == 0) return;
        chip.mint(msg.sender, owed);
    }

    function _claimFromPlayer(uint16 tokenId, bool unstake) internal returns (uint owed) {
        Stake memory stake = chipPlayerStake[msg.sender][chipPlayerIndices[tokenId]];
        require(stake.owner == msg.sender, "This NTF does not belong to address");
        require(!(unstake && block.timestamp - stake.value < MINIMUM_TIME_TO_EXIT), "Need to wait 1 day since last claim");
        //conditional to determine if only 1 burn a day is on.
        if(checkForBurnOn) {
            checkForBurn();
        }


        if (totalChipEarned < MAXIMUM_GLOBAL_CHIP) {
            if(!alreadyBurnt && bust == true) {
                //if bust protocol is activated 1% will be burnt.
                uint toOwe = ((block.timestamp - stake.value) * DAILY_CHIP_RATE) / 1 days;
                uint afterBurn = bustProtocol(toOwe);
                owed = afterBurn;
            } else {
                owed = ((block.timestamp - stake.value) * DAILY_CHIP_RATE) / 1 days;
            }
            
        } else if (stake.value > lastClaimTimestamp) {
            owed = 0; // $CHIPS production stopped already
        } else {
            //if bust protocol is activated 1% will be burnt.
            if(!alreadyBurnt && bust == true) {
                uint toOwe2 = ((lastClaimTimestamp - stake.value) * DAILY_CHIP_RATE) / 1 days; // stop earning additional $CHIPS if it's all been earned
                uint afterBurn = bustProtocol(toOwe2);
                owed = afterBurn;
            } else {
                owed = ((lastClaimTimestamp - stake.value) * DAILY_CHIP_RATE) / 1 days; // stop earning additional $CHIPS if it's all been earned
            }
        }
        if (unstake) {
            if (getSomeRandomNumber(tokenId, 100) <= 50) {
                //wrote burn code here but commented out since the burn is handled above. owed is updated before reaching here and the 1% reduction passes through here and onto the taxes the loansharks receive. To be deleted on official launch.
                
                // uint afterBurn = bustProtocol(owed);
                _payTax(owed);
                owed = 0;
                // afterBurn = 0;
            }
            updateRandomIndex();
            totalChipPlayerStaked -= 1;

            Stake memory lastStake = chipPlayerStake[msg.sender][chipPlayerStake[msg.sender].length - 1];
            chipPlayerStake[msg.sender][chipPlayerIndices[tokenId]] = lastStake;
            chipPlayerIndices[lastStake.tokenId] = chipPlayerIndices[tokenId];
            chipPlayerStake[msg.sender].pop();
            delete chipPlayerIndices[tokenId];

            player.safeTransferFrom(address(this), msg.sender, tokenId, "");
        } else {
            //wrote burn code here but commented out since the burn is handled above. owed is updated before reaching here and the 1% reduction passes through here and onto the taxes the loansharks receive. To be deleted on official launch.

            // uint afterBurn = bustProtocol(owed);
            _payTax((owed * TAX_PERCENTAGE) / 100); // Pay some $CHIPS to loanSharks!
            owed = (owed * (100 - TAX_PERCENTAGE)) / 100;
            
            uint80 timestamp = uint80(block.timestamp);

            chipPlayerStake[msg.sender][chipPlayerIndices[tokenId]] = Stake({
                owner: msg.sender,
                tokenId: uint16(tokenId),
                value: timestamp
            }); // reset stake
        }

        emit ChipPlayerClaimed(tokenId, owed, unstake);
    }

    function _claimFromLoanShark(uint16 tokenId, bool unstake) internal returns (uint owed) {
        require(player.ownerOf(tokenId) == address(this), "This NTF does not belong to address");

        Stake memory stake = loanSharkStake[msg.sender][loanSharkIndices[tokenId]];

        require(stake.owner == msg.sender, "This NTF does not belong to address");
        //1% is already burnt from all players chip. loanShark owed variable is derived from loanSharkReward, which is derived from the taxes paid by the players after 1% has already been burnt. So the burn flows here transitively and no need to burn again.
        owed = (loanSharkReward - stake.value);

        if (unstake) {
            totalLoanSharkStaked -= 1; // Remove Alpha from total staked

            Stake memory lastStake = loanSharkStake[msg.sender][loanSharkStake[msg.sender].length - 1];
            loanSharkStake[msg.sender][loanSharkIndices[tokenId]] = lastStake;
            loanSharkIndices[lastStake.tokenId] = loanSharkIndices[tokenId];
            loanSharkStake[msg.sender].pop();
            delete loanSharkIndices[tokenId];
            updateLoanSharkOwnerAddressList(msg.sender);

            player.safeTransferFrom(address(this), msg.sender, tokenId, "");
        } else {
            loanSharkStake[msg.sender][loanSharkIndices[tokenId]] = Stake({
                owner: msg.sender,
                tokenId: uint16(tokenId),
                value: uint80(loanSharkReward)
            }); // reset stake
        }
        emit LoanSharkClaimed(tokenId, owed, unstake);
    }

    function updateLoanSharkOwnerAddressList(address account) internal {
        if (loanSharkStake[account].length != 0) {
            return; // No need to update holders
        }

        // Update the address list of holders, account unstaked all loanSharks
        address lastOwner = loanSharkHolders[loanSharkHolders.length - 1];
        uint indexOfHolder = 0;
        for (uint i = 0; i < loanSharkHolders.length; i++) {
            if (loanSharkHolders[i] == account) {
                indexOfHolder = i;
                break;
            }
        }
        loanSharkHolders[indexOfHolder] = lastOwner;
        loanSharkHolders.pop();
    }

    function rescue(uint16[] calldata tokenIds) external {
        require(rescueEnabled, "Rescue disabled");
        uint16 tokenId;
        Stake memory stake;

        for (uint16 i = 0; i < tokenIds.length; i++) {
            tokenId = tokenIds[i];
            if (!player.isLoanShark(tokenId)) {
                stake = chipPlayerStake[msg.sender][chipPlayerIndices[tokenId]];

                require(stake.owner == msg.sender, "This NTF does not belong to address");

                totalChipPlayerStaked -= 1;

                Stake memory lastStake = chipPlayerStake[msg.sender][chipPlayerStake[msg.sender].length - 1];
                chipPlayerStake[msg.sender][chipPlayerIndices[tokenId]] = lastStake;
                chipPlayerIndices[lastStake.tokenId] = chipPlayerIndices[tokenId];
                chipPlayerStake[msg.sender].pop();
                delete chipPlayerIndices[tokenId];

                player.safeTransferFrom(address(this), msg.sender, tokenId, "");

                emit ChipPlayerClaimed(tokenId, 0, true);
            } else {
                stake = loanSharkStake[msg.sender][loanSharkIndices[tokenId]];
        
                require(stake.owner == msg.sender, "This NTF does not belong to address");

                totalLoanSharkStaked -= 1;
                
                    
                Stake memory lastStake = loanSharkStake[msg.sender][loanSharkStake[msg.sender].length - 1];
                loanSharkStake[msg.sender][loanSharkIndices[tokenId]] = lastStake;
                loanSharkIndices[lastStake.tokenId] = loanSharkIndices[tokenId];
                loanSharkStake[msg.sender].pop();
                delete loanSharkIndices[tokenId];
                updateLoanSharkOwnerAddressList(msg.sender);
                
                player.safeTransferFrom(address(this), msg.sender, tokenId, "");
                
                emit LoanSharkClaimed(tokenId, 0, true);
            }
        }
    }

    function _payTax(uint _amount) internal {
        if (totalLoanSharkStaked == 0) {
            unaccountedRewards += _amount;
            return;
        }

        loanSharkReward += (_amount + unaccountedRewards) / totalLoanSharkStaked;
        unaccountedRewards = 0;
    }


    modifier _updateEarnings() {
        if (totalChipEarned < MAXIMUM_GLOBAL_CHIP) {
            totalChipEarned += ((block.timestamp - lastClaimTimestamp) * totalChipPlayerStaked * DAILY_CHIP_RATE) / 1 days;
            lastClaimTimestamp = block.timestamp;
        }
        _;
    }


    function setRescueEnabled(bool _enabled) external onlyOwner {
        rescueEnabled = _enabled;
    }

    function setPaused(bool _state) external onlyOwner {
        _paused = _state;
    }


    function randomLoanSharkOwner() external returns (address) {
        if (totalLoanSharkStaked == 0) return address(0x0);

        uint holderIndex = getSomeRandomNumber(totalLoanSharkStaked, loanSharkHolders.length);
        updateRandomIndex();

        return loanSharkHolders[holderIndex];
    }

    function updateRandomIndex() internal {
        _randomIndex += 1;
        _randomCalls += 1;
        if (_randomIndex > 6) _randomIndex = 0;
    }

    function getSomeRandomNumber(uint _seed, uint _limit) internal view returns (uint16) {
        uint extra = 0;
        for (uint16 i = 0; i < 7; i++) {
            extra += _randomSource[_randomIndex].balance;
        }

        uint random = uint(
            keccak256(
                abi.encodePacked(
                    _seed,
                    blockhash(block.number - 1),
                    block.coinbase,
                    block.difficulty,
                    msg.sender,
                    extra,
                    _randomCalls,
                    _randomIndex
                )
            )
        );

        return uint16(random % _limit);
    }

    function changeRandomSource(uint _id, address _address) external onlyOwner {
        _randomSource[_id] = _address;
    }

    function shuffleSeeds(uint _seed, uint _max) external onlyOwner {
        uint shuffleCount = getSomeRandomNumber(_seed, _max);
        _randomIndex = uint16(shuffleCount);
        for (uint i = 0; i < shuffleCount; i++) {
            updateRandomIndex();
        }
    }

    function onERC721Received(
        address,
        address from,
        uint,
        bytes calldata
    ) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to this contact directly");
        return IERC721Receiver.onERC721Received.selector;
    }

    //bust protocol to burn tokens
    //ensure sending address is added as manager when calling mint from Chips.sol in this function. Use addManager function from Chips.sol to do this.
    function bustProtocol(uint amount) public returns (uint){
        //divide by 100 to get 1%. Done with integer division, as solidity doesnt support floating point. As such numbers are not exactly 1%.
        uint burn = amount / 100;
        chip.mint(burnWall, burn);
        return amount - burn;
    }

    //used to turn bust protocol on and off. If off nothing is burnt at all.
    function setBust(bool tempBust) public {
        //Could use OnlyOwner instead for this
        require(msg.sender == bustMan, "Access Denied");
        bust = tempBust;
    }

    //checks if a day has passed to do another burn. Ensures only 1 burn a day occurs. Can be turned off with setCheckForBurnOn.
    function checkForBurn() public {
        //checks difference between now and last burn
        uint diff = block.timestamp - sinceBurn;
        //if diff >= secondsPerDay then it has been longer than a day so alreadyBurnt is false and sinceBurn is updated to now for the next check.
        if (diff >= secondsPerDay) {
            alreadyBurnt = false;
            sinceBurn = block.timestamp;
        } else {
            alreadyBurnt = true;
        }

    }

    //turns on and off the function of only allowing 1 burn per day.
    function setCheckForBurnOn(bool isOn) external onlyOwner {
        checkForBurnOn = isOn;
    }



}