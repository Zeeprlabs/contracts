// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

import "./Interfaces.sol";
import "./Perpetual.sol";

contract PrivatePool is IPool, Ownable {
    using SafeMath for uint256;

    bytes4 private constant SELECTOR_TRANSFER_FROM = bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));
    bytes4 private constant SELECTOR_TRANSFER = bytes4(keccak256(bytes("transfer(address,uint256)")));
    //    IPerpetualPublicPool publicPool;
    uint256 internal constant PRICE_DECIMALS = 1e18;
    uint256 internal constant RATIO_DECIMALS = 1e18;
    uint256 private minMintAmount = 1e18;
    uint256 private marginRatio = (1 * RATIO_DECIMALS) / 100; // Margin fee rate for private pool, 1%
    uint256 private addMarginRatio = (10 * RATIO_DECIMALS) / 100; // additional Margin fee rate for private pool, 10%
    uint256 private maintenanceMarginRate = (2 * RATIO_DECIMALS) / 1000; // 0.2% for private maker liquidation fee


    address public tokenAddress;
    MakerDeal[] public makerDeals;
    mapping(address => uint256) public lastProvideTm;
    mapping(address => bool) public addressExist;
    mapping(address => LP2Account) public lpAccount;

    modifier onlyKeeper() {
        require(keeperMap[msg.sender], "caller is not private pool keeper");
        _;
    }

    /**
     * @dev Contract constructor.
     * @param _tokenAddress Fiat token address(DAI/USDT/USDC).
     * @param _riskFundAddr Risk fund address.
     */
    constructor(
    //        address _publicPool,
        address _tokenAddress,
        address _riskFundAddr
    ) public {
        riskFundAddr = _riskFundAddr;
        tokenAddress = _tokenAddress;
    }

    /**
     * @dev Stake in private pool.
     * @param _amount stake amount
     */
    function provide(uint256 _amount) public {
        require(_amount >= minMintAmount, "Mint Amount is too small");
        lastProvideTm[msg.sender] = block.timestamp;
        _safeTransferFrom(tokenAddress, msg.sender, address(this), _amount);
        LP2Account memory lp2Account = lpAccount[msg.sender];
        lp2Account.amount = lp2Account.amount.add(_amount);
        lp2Account.availableAmount = lp2Account.availableAmount.add(_amount);
        lp2Account.holder = msg.sender;
        if (!addressExist[msg.sender]) {
            addressExist[msg.sender] = true;
            lpAddr.push(msg.sender);
            lp2Account.autoAddMargin = true;
        }
        lpAccount[msg.sender] = lp2Account;
        emit ProvideLP2(msg.sender, _amount);
    }

    /**
     * @dev UnStake from private pool.
     * @param _amount unStake amount
     */
    function withdraw(uint256 _amount) public {
        require(lastProvideTm[msg.sender].add(lockupPeriod) <= block.timestamp, "locked up");
        LP2Account memory lp2Account = lpAccount[msg.sender];
        require((personalizeMaker && _amount <= lp2Account.availableAmount) || _amount <= lpAccount[unionMakerAddress].availableAmount, "Pool: lower the amount.");
        if (personalizeMaker) {
            lp2Account.amount = lp2Account.amount.sub(_amount);
            lp2Account.availableAmount = lp2Account.availableAmount.sub(_amount);
        }

        lpAccount[msg.sender] = lp2Account;
        _safeTransfer(tokenAddress, msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }




    function checkMarginRisk(uint256 _dealID, uint256 _profit) public view returns (bool isRisk)  {
        MakerDeal memory makerDeal = makerDeals[matchIds[_dealID] - 1];
        return _profit >= makerDeal.marginAmount;
    }



    function getLPAmountInfo() public view returns (uint256 deposit, uint256 available, uint256 locked) {
        deposit = totalBalance();
        locked = getLPLocked();
        available = deposit.sub(locked);
    }

    function getLPLocked() public view returns (uint256 locked) {
        locked = totalLockedLiquidity;
    }

    function setIsRejectOrder(bool _flag) public {
        require(addressExist[msg.sender], "need deposit");
        lpAccount[msg.sender].isRejectOrder = _flag;
    }

    function setAutoAddMargin(bool _flag) public {
        require(addressExist[msg.sender], "need deposit");
        lpAccount[msg.sender].autoAddMargin = _flag;
    }

    function setUserRatio(uint256 mean, uint256 value) public {
        require(addressExist[msg.sender], "user is not exists");
        if (mean == 1) {
            lpAccount[msg.sender].marginRate = value;
        } else if (mean == 2) {
            lpAccount[msg.sender].maintenanceMarginRate = value;
        } else if (mean == 3) {
            lpAccount[msg.sender].addMarginRate = value;
        } else if (mean == 4) {
            lpAccount[msg.sender].commissionDiscountFee = value;
        }
    }

    //return all maker address
    function getMakerAddresses() public view returns (address[] memory){
        return lpAddr;
    }

   
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        value = transmitValueDecimal(token, value);
        if (value > 0) {
            (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR_TRANSFER_FROM, from, to, value));
            require(success && (data.length == 0 || abi.decode(data, (bool))));
        }
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        value = transmitValueDecimal(token, value);
        if (value > 0) {
            (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR_TRANSFER, to, value));
            require(success && (data.length == 0 || abi.decode(data, (bool))));
        }
    }

    function transmitValueDecimal(address token, uint256 value) internal view returns (uint256){
        uint256 length = BEP20(token).decimals();
        return value.mul(10 ** length).div(PRICE_DECIMALS);
    }
}
