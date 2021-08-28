// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/Address.sol";

import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/utils/Pausable.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";

import "../defi/klayswap.sol";

contract StratKSP is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in klayswap
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    mapping(address => bool) members;

    bool public isAutoComp; // this vault is purely for staking(true)

    address public wantAddress;
    address public token0Address; // KLAY or Kct
    address public token1Address; // Kct only
    address public earnedAddress; // KlaySwap Protocol
    address public uniRouterAddress; // KlaySwap Factory

    address public ORCAProtocolAddress;
    address public ORCAAddress;
    address public govAddress;
    bool public onlyGov = true;

    uint256 public lastEarnBlock = 0;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    uint256 public controllerFee = 150;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%
    uint256 public constant controllerFeeUL = 300;

    uint256 public buyBackRate = 350;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    uint256 public constant buyBackRateUL = 800;
    address public buyBackAddress = 0x000000000000000000000000000000000000dEaD;
    address public rewardsAddress;

    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool + prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public withdrawFeeFactor = 10000; // 0.1% withdraw fee - goes to pool
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToORCAPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    event SetSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _slippageFactor
    );

    event SetGov(address _govAddress);
    event SetOnlyGov(bool _onlyGov);
    event SetUniRouterAddress(address _uniRouterAddress);
    event SetBuyBackAddress(address _buyBackAddress);
    event SetRewardsAddress(address _rewardsAddress);

    modifier onlyAllowGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    constructor(
        address[] memory _addresses,
        bool _isAutoComp,
        address[] memory _earnedToORCAPath,
        address[] memory _earnedToToken0Path,
        address[] memory _earnedToToken1Path,
        address[] memory _token0ToEarnedPath,
        address[] memory _token1ToEarnedPath,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor
    ) public {
        govAddress = _addresses[0];
        ORCAProtocolAddress = _addresses[1];
        ORCAAddress = _addresses[2];

        wantAddress = _addresses[3];
        token0Address = _addresses[4];
        token1Address = _addresses[5];
        earnedAddress = _addresses[6];

        isAutoComp = _isAutoComp;

        uniRouterAddress = _addresses[7];
        earnedToORCAPath = _earnedToORCAPath;
        earnedToToken0Path = _earnedToToken0Path;
        earnedToToken1Path = _earnedToToken1Path;
        token0ToEarnedPath = _token0ToEarnedPath;
        token1ToEarnedPath = _token1ToEarnedPath;

        controllerFee = _controllerFee;
        rewardsAddress = _addresses[8];

        buyBackRate = _buyBackRate;
        buyBackAddress = _addresses[9];
        entranceFeeFactor = _entranceFeeFactor;
        withdrawFeeFactor = _withdrawFeeFactor;

        transferOwnership(ORCAProtocolAddress);
    }

    // Receives new deposits from user
    function deposit(address _userAddress, uint256 _wantAmt)
        public
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        require(!isMember(_userAddress), "!auth");

        IERC20(wantAddress).transferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal > 0 && sharesTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .mul(entranceFeeFactor)
                .div(wantLockedTotal)
                .div(entranceFeeFactorMax);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        _farm();

        return sharesAdded;
    }

    function farm() public nonReentrant {
        _farm();
    }

    function _farm() internal {
        wantLockedTotal = IERC20(wantAddress).balanceOf(address(this));
    }

    function withdraw(address _userAddress, uint256 _wantAmt)
        public
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        require(_wantAmt > 0, "_wantAmt <= 0");

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);

        if (withdrawFeeFactor < withdrawFeeFactorMax) {
            _wantAmt = _wantAmt.mul(withdrawFeeFactor).div(
                withdrawFeeFactorMax
            );
        }

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        IERC20(wantAddress).transfer(ORCAProtocolAddress, _wantAmt);

        return sharesRemoved;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into want tokens

    function earn() public whenNotPaused nonReentrant {
        require(isAutoComp, "!isAutoComp");
        if (onlyGov) {
            require(msg.sender == govAddress, "!gov");
        }

        // Harvest farm tokens
        IKSLP(wantAddress).claimReward();

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        if (earnedAmt == 0) {
            return;
        }

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        IERC20(earnedAddress).approve(uniRouterAddress, 0);
        increaseApproval(earnedAddress, uniRouterAddress, earnedAmt);

        if (earnedAddress != token0Address) {
            _safeSwap(
                uniRouterAddress,
                earnedAmt.div(2),
                slippageFactor,
                earnedAddress,
                token0Address,
                earnedToToken0Path
            );
        }

        if (earnedAddress != token1Address) {
            _safeSwap(
                uniRouterAddress,
                earnedAmt.div(2),
                slippageFactor,
                earnedAddress,
                token1Address,
                earnedToToken1Path
            );
        }

        // Create wantToken
        // Check if tokenA is KLAY
        uint256 token0Amt = (payable(address(this))).balance;
        if (token0Address != address(0)) {
            token0Amt = IERC20(token0Address).balanceOf(address(this));
        }
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));

        if (token0Amt > 0 && token1Amt > 0) {
            increaseApproval(token1Address, wantAddress, token1Amt);

            if (token0Address != address(0)) {
                // KCT-KCT pair
                increaseApproval(token0Address, wantAddress, token0Amt);
                IKSLP(wantAddress).addKctLiquidity(token0Amt, token1Amt);
            } else {
                // KLAY-KCT pair
                IKSLP(wantAddress).addKlayLiquidity{value: token0Amt}(
                    token1Amt
                );
            }
        }

        lastEarnBlock = block.number;
        _farm();
    }

    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate <= 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);

        if (earnedAddress == ORCAAddress) {
            IERC20(earnedAddress).transfer(buyBackAddress, buyBackAmt);
        } else {
            increaseApproval(earnedAddress, uniRouterAddress, buyBackAmt);
            _safeSwap(
                uniRouterAddress,
                buyBackAmt,
                slippageFactor,
                earnedAddress,
                ORCAAddress,
                earnedToORCAPath
            );
            uint256 buyBackORCAAmt = IERC20(ORCAAddress).balanceOf(
                address(this)
            );
            IERC20(earnedAddress).transfer(buyBackAddress, buyBackORCAAmt);
        }

        return _earnedAmt.sub(buyBackAmt);
    }

    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0) {
            // Performance fee
            if (controllerFee > 0) {
                uint256 fee = _earnedAmt.mul(controllerFee).div(
                    controllerFeeMax
                );
                IERC20(earnedAddress).transfer(rewardsAddress, fee);
                _earnedAmt = _earnedAmt.sub(fee);
            }
        }

        return _earnedAmt;
    }

    function convertDustToEarned() public whenNotPaused nonReentrant {
        require(isAutoComp, "!isAutoComp");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens

        uint256 token0Amt = (payable(address(this))).balance;
        if (token0Address != address(0)) {
            token0Amt = IERC20(token0Address).balanceOf(address(this));
            increaseApproval(token0Address, uniRouterAddress, token0Amt);
        }

        if (token0Address != earnedAddress && token0Amt > 0) {
            _safeSwap(
                uniRouterAddress,
                token0Amt,
                slippageFactor,
                token0Address,
                earnedAddress,
                token0ToEarnedPath
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Address != earnedAddress && token1Amt > 0) {
            increaseApproval(token1Address, uniRouterAddress, token1Amt);
            _safeSwap(
                uniRouterAddress,
                token1Amt,
                slippageFactor,
                token1Address,
                earnedAddress,
                token1ToEarnedPath
            );
        }
    }

    function _safeSwap(
        address _swapRouterAddress,
        uint256 _amountIn,
        uint256 _slippageFactor,
        address _from,
        address _to,
        address[] memory _path
    ) internal {
        address[] memory route = _makeRoutePath(_from, _to, _path);
        uint256[] memory amounts = _getAmountsOut(
            _swapRouterAddress,
            _amountIn,
            route
        );
        uint256 amountOut = amounts[amounts.length.sub(1)]
            .mul(_slippageFactor)
            .div(1000);

        if (_from != address(0)) {
            IKSP(_swapRouterAddress).exchangeKctPos(
                _from,
                _amountIn,
                _to,
                amountOut,
                _path
            );
        } else {
            IKSP(_swapRouterAddress).exchangeKlayPos{value: _amountIn}(
                _to,
                amountOut,
                _path
            );
        }
    }

    function _makeRoutePath(
        address _from,
        address _to,
        address[] memory _path
    ) internal pure returns (address[] memory) {
        address[] memory route = new address[](_path.length.add(2));

        route[0] = _from;
        if (_path.length != 0) {
            for (uint256 i; i < _path.length; i++) {
                route[i.add(1)] = _path[i];
            }
        }
        route[route.length.sub(1)] = _to;

        return route;
    }

    function _getAmountsOut(
        address _factory,
        uint256 _amountIn,
        address[] memory _path
    ) internal view returns (uint256[] memory amounts) {
        require(_path.length >= 2, "INVALID_PATH");

        amounts = new uint256[](_path.length);
        amounts[0] = _amountIn;
        for (uint256 i; i < _path.length.sub(1); i++) {
            address pair = IKSP(_factory).tokenToPool(
                _path[i],
                _path[i.add(1)]
            );
            uint256 estimated = IKSLP(pair).estimatePos(_path[i], amounts[i]);
            amounts[i.add(1)] = estimated;
        }
    }

    function setSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _slippageFactor
    ) public onlyAllowGov {
        require(
            _entranceFeeFactor >= entranceFeeFactorLL,
            "_entranceFeeFactor too low"
        );
        require(
            _entranceFeeFactor <= entranceFeeFactorMax,
            "_entranceFeeFactor too high"
        );
        entranceFeeFactor = _entranceFeeFactor;

        require(
            _withdrawFeeFactor >= withdrawFeeFactorLL,
            "_withdrawFeeFactor too low"
        );
        require(
            _withdrawFeeFactor <= withdrawFeeFactorMax,
            "_withdrawFeeFactor too high"
        );
        withdrawFeeFactor = _withdrawFeeFactor;

        require(_controllerFee <= controllerFeeUL, "_controllerFee too high");
        controllerFee = _controllerFee;

        require(_buyBackRate <= buyBackRateUL, "_buyBackRate too high");
        buyBackRate = _buyBackRate;

        require(
            _slippageFactor <= slippageFactorUL,
            "_slippageFactor too high"
        );
        slippageFactor = _slippageFactor;

        emit SetSettings(
            _entranceFeeFactor,
            _withdrawFeeFactor,
            _controllerFee,
            _buyBackRate,
            _slippageFactor
        );
    }

    function pause() public onlyAllowGov {
        _pause();
    }

    function unpause() public onlyAllowGov {
        _unpause();
    }

    function setGov(address _govAddress) public onlyAllowGov {
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) public onlyAllowGov {
        onlyGov = _onlyGov;
    }

    function setUniRouterAddress(address _uniRouterAddress)
        public
        onlyAllowGov
    {
        uniRouterAddress = _uniRouterAddress;
        emit SetUniRouterAddress(_uniRouterAddress);
    }

    function setBuyBackAddress(address _buyBackAddress) public onlyAllowGov {
        buyBackAddress = _buyBackAddress;
        emit SetBuyBackAddress(_buyBackAddress);
    }

    function setRewardsAddress(address _rewardsAddress) public onlyAllowGov {
        rewardsAddress = _rewardsAddress;
        emit SetRewardsAddress(_rewardsAddress);
    }

    function increaseApproval(
        address token,
        address to,
        uint256 amount
    ) private {
        uint256 allowance = IERC20(token).allowance(address(this), to);
        IERC20(token).approve(to, allowance.add(amount));
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) public onlyAllowGov nonReentrant {
        require(_token != earnedAddress, "!safe");
        require(_token != wantAddress, "!safe");
        require(_token != token0Address, "!safe");
        require(_token != token1Address, "!safe");

        if (_token != address(0)) {
            IERC20(_token).transfer(_to, _amount);
        } else {
            (bool success, ) = (_to).call{value: _amount}("");
            require(success, "Transfer failed.");
        }
    }

    function isMember(address _member) public view returns (bool) {
        return members[_member];
    }

    function addMember(address _member) public onlyAllowGov {
        require(!isMember(_member), "Address is member already.");
        members[_member] = true;
    }

    function removeMember(address _member) public onlyAllowGov {
        require(isMember(_member), "Not member of whitelist.");
        delete members[_member];
    }

    receive() external payable {}
}

