// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/**
 * @notice USD Margin perpetual contract.
 */
contract Perpetual is  Ownable {

    uint256 internal constant PRICE_DECIMALS = 1e18;
    address private fiatTokenAddr; // Base fiat token address
    address private buybackAddr; // contract address for buyback
    address private riskFundAddr; // risk fund address
    address private tradeFeeAddr; // trade fee collection fund address

    mapping(address => AccountInfo) public userAccount;
    address[] private userAddresses;
    uint256 private minDepositAmount = 1e18; // minimum deposit amount
    uint256 private maintenanceMarginRate = 1e17; // means 10%
    uint256 private toBuyBackPercent = (30 * 1e18) / 100; // means trade fee percent to buy back addr  50%

    bool private mergeAgentFeeToBuyBack;
    uint256 private unlocked = 1;

    modifier lock() {
        require(unlocked == 1, "LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier ensure(uint256 _deadline) {
        require(_deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlyKeeper() {
        require(keeperMap[msg.sender] || msg.sender == localCaller, "caller is not perpetual keeper");
        _;
        localCaller = address(0x0);
    }

    // Function selectors for BEP20
    bytes4 internal constant SELECTOR_TRANSFER_FROM = bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));
    bytes4 internal constant SELECTOR_TRANSFER = bytes4(keccak256(bytes("transfer(address,uint256)")));
    bytes4 internal constant SELECTOR_APPROVE = bytes4(keccak256(bytes("approve(address,uint256)")));

    constructor(
        address _riskFundAddr,
        address _fiatTokenAddr
    //        StableCoinType _type
    ) public {
        riskFundAddr = _riskFundAddr;
        fiatTokenAddr = _fiatTokenAddr;
    }

    /**
     * @dev Deposit USD assets to trade on LONG/SHORT futures.
     * @param _amount Amount of fiat token to deposit.
     */
    function deposit(uint256 _amount) public {
        require(_amount >= minDepositAmount, "too small");
        AccountInfo storage userAcc = userAccount[msg.sender];

        _safeTransferFrom(fiatTokenAddr, msg.sender, address(this), _amount);
        userAcc.depositAmount = userAcc.depositAmount.add(_amount);
        userAcc.availableAmount = userAcc.availableAmount.add(_amount);
        if (userAcc.lastTime == 0) {
            userAcc.lastTime = block.timestamp;
            userAddresses.push(msg.sender);
        }
        emitTransactionHistory(msg.sender, TransactionType.DEPOSIT, _amount);
    }

    /**
     * @dev Withdraw USD assets from smart contract.
     * @param _amount Amount of fiat token to withdraw.
     */
    function withdraw(uint256 _amount) public lock {
        AccountInfo storage userAcc = userAccount[msg.sender];
        uint256 userLoss;
        (bool flag, uint256 pnl) = tradeAgent.getPNL(msg.sender);
        if (!flag) {
            userLoss = pnl;
        }
        require(userAcc.availableAmount >= _amount.add(userLoss), "exceed");
        userAcc.depositAmount = userAcc.depositAmount.sub(_amount);
        userAcc.availableAmount = userAcc.availableAmount.sub(_amount);
        _safeTransfer(fiatTokenAddr, msg.sender, _amount);
        emitTransactionHistory(msg.sender, TransactionType.WITHDRAW, _amount);
    }

    /**
     * @dev Trading on buying or selling futures.
     * @param _name Exchange name of a transaction (i.e. ETH, BTC).
     * @param _amount Trading amount.
     * @param _price Price on a limit order (Market order should be 0).
     * @param _slidePrice Used to calculate price slippage on a market order.
     * @param _type 1 - LONG(Buy) / 2 - SHORT(Sell).
     * @param _inviter Broker address.
     * @param _goodTill Limit order good until this timestamp.
     * @param _deadline Transaction expired timestamp.
     */
    function tradeFutures(
        string memory _name,
        uint256 _amount,
        uint256 _price,
        uint256 _slidePrice,
        ContractType _type,
        address _inviter,
        uint256 _goodTill,
        uint256 _deadline
    ) public lock ensure(_deadline) {
        require(_type == ContractType.LONG || _type == ContractType.SHORT, "wrong type");
        if (_price == 0 || (_type == ContractType.LONG && prices.upperPrice <= _price) || (_type == ContractType.SHORT && prices.lowerPrice >= _price)) {
            //            string memory debugHint = strConcat(tradeAgent.uint2str(prices.upperPrice), '|', tradeAgent.uint2str(prices.lowerPrice), '|', tradeAgent.uint2str(_slidePrice));
            require((_type == ContractType.LONG && prices.upperPrice <= _slidePrice) || (_type == ContractType.SHORT && prices.lowerPrice >= _slidePrice), "slippage");
            makeOpenMarketOrder(msg.sender, _name, _amount, 0, _type, false);
        } else {
            makeOpenLimitOrder(msg.sender, _name, _amount, _price, _type, _goodTill);
        }
    }

    function makeOpenLimitOrder(address payable _taker, string memory _name, uint256 _amount, uint256 _price, ContractType _type, uint256 _goodTill) public onlyKeeper {
        Fees memory fee;
        (, fee.marginAmount, fee.tradingFee, fee.extraFee, fee.totalLocked,,) = assetsNameMapping[_name].getFees(address(this), _amount, _type, _price, false, userAccount[_taker].leverage);
        AccountInfo storage account = userAccount[_taker];
        require(account.availableAmount >= fee.totalLocked, "exceed");
        account.availableAmount = account.availableAmount.sub(fee.totalLocked);
        account.orderLocked = account.orderLocked.add(fee.totalLocked);
    }

    function makeOpenMarketOrder(address payable _taker, string memory _name, uint256 _amount, uint256 _price, ContractType _type, bool trigger) public onlyKeeper {
        Fees memory fee;
        (fee.total, fee.marginAmount, fee.tradingFee, fee.extraFee, fee.totalLocked,, fee.dealPrice) = assetsNameMapping[_name].getFees(address(this), _amount, _type, _price, true, userAccount[_taker].leverage);
        // Update user wallet
        AccountInfo storage account = userAccount[_taker];
        require(account.availableAmount >= fee.totalLocked, "exceed");

        account.depositAmount = account.depositAmount.sub(fee.tradingFee);
        if (trigger && fee.totalLocked >= fee.extraFee) {
            //do not taker trade fee
            fee.totalLocked = fee.totalLocked.sub(fee.extraFee);
        }
        account.availableAmount = account.availableAmount.sub(fee.totalLocked);
        account.marginAmount = account.marginAmount.add(fee.marginAmount);
        // transfer buyback fee to buyback pool
    }

    function closePosition(string memory _name, uint256 _amount, uint256 _slidePrice, uint256 _targetPrice, ContractType _type, uint256 _goodTill, uint256 _deadline) public lock ensure(_deadline) {
        require(_amount > 0, "amount is zero");
        require(_type == ContractType.LONG || _type == ContractType.SHORT, "wrong type");
        ClosePosition memory position;
        (position.positionValue, position.positionSize,, position.freezeSize) = orderBook.positions(msg.sender, _name, uint8(_type) - 1);
        require(_amount <= position.positionSize.sub(position.freezeSize), "close amount exceed");

        position.price = asset.getPrice(address(this), true);
        localCaller = msg.sender;
        if (_targetPrice == 0 || (_type == ContractType.LONG && position.price >= _targetPrice) || (_type == ContractType.SHORT && position.price <= _targetPrice)) {
            //            string memory debugHint = strConcat(tradeAgent.uint2str(_amount), '|', tradeAgent.uint2str(position.price), '|', tradeAgent.uint2str(_slidePrice));
            require((_type == ContractType.LONG && position.price >= _slidePrice) || (_type == ContractType.SHORT && position.price <= _slidePrice), "slippage");
            makeCloseMarketOrder(msg.sender, _name, _amount, position.price, _type);
        } else {
            tradeStation.makeCloseLimitOrder(msg.sender, _name, _amount, _targetPrice, _type, _goodTill);
        }
    }


    function transferToken(address sender, address received, uint256 tradingFee, uint256 transmitAmount, TransactionType transType) internal returns (uint256 remain){
        remain = tradingFee;
        if (received != address(0x0) && tradingFee > 0 && transmitAmount > 0) {
            if (tradingFee >= transmitAmount) {
                remain = tradingFee.sub(transmitAmount);
            } else {
                transmitAmount = tradingFee;
                remain = 0;
            }
            _safeTransfer(fiatTokenAddr, received, transmitAmount);
            emitTransferFee(sender, received, transType, transmitAmount);
        }
        return remain;
    }

    function cancelOrders(uint256[] memory _orderIDs) public {
        for (uint256 i = 0; i < _orderIDs.length; i++) {
            localCaller = msg.sender;
            cancelOrder(_orderIDs[i], msg.sender, false);
        }
    }


    function getMaxBalance(uint256 depotAmount) internal view returns (uint256 amount){
        uint256 contractBalance = getTokenAmount4Address(address(this));
        if (depotAmount > contractBalance) {
            return contractBalance;
        }
        return depotAmount;
    }

    function getPNL(address _user) public view returns (bool flag, uint256 amount) {
        return tradeAgent.getPNL(_user);
    }

    function getMaxOpenAmount(address _user, string memory _name, uint256 _price, ContractType _type) public view returns (uint256 amount) {
        return tradeAgent.getMaxOpenAmount(_user, _name, _price, _type);
    }

    function getMaxWithdrawableAmount(address _user) public view returns (uint256 _amount) {
        return tradeAgent.getMaxWithdrawableAmount(_user);
    }

    /**
     * @dev Check whether maker margin of certain deal is at risk or not
     * @param _dealID Deal ID need to be check
     * @return isRisk - 0 indicates not at risk, 1 indicates at risk
     */
    function checkMakerMarginRisk(uint256 _dealID) public view returns (bool isRisk) {
        isRisk = tradeAgent.checkMakerMarginRisk(_dealID);
    }

    function checkTakerMarginRisk(address _taker) public view returns (bool isRisk) {
        uint256 maintenanceMargin = userAccount[_taker].marginAmount.mul(maintenanceMarginRate).div(PRICE_DECIMALS);
        (isRisk,,,) = tradeAgent.checkTakerMarginRisk(_taker, tradingPairs.length, maintenanceMargin, 2);
    }


    function emitTransactionHistory(address sender, TransactionType _type, uint256 _amount) internal {
        emit TransactionHistory(sender, _type, _amount, block.timestamp);
    }

    function emitTransferFee(address sender, address received, TransactionType _type, uint256 _amount) internal {
        emit TransferFee(sender, received, _type, _amount, block.timestamp);
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

    function _safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR_APPROVE, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function transmitValueDecimal(address token, uint256 value) internal view returns (uint256){
        uint256 length = BEP20(token).decimals();
        return value.mul(10 ** length).div(PRICE_DECIMALS);
    }
}
