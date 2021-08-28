// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IKSLP {
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function claimReward() external;
    function estimatePos(address token, uint256 amount) external view returns (uint256);
    function estimateNeg(address token, uint256 amount) external view returns (uint256);
    function addKlayLiquidity(uint256 amount) external payable;
    function addKctLiquidity(uint256 amountA, uint256 amountB) external;
    function removeLiquidity(uint256 amount) external;
    function getCurrentPool() external view returns (uint256, uint256);
    function addKctLiquidityWithLimit(uint256 amountA, uint256 amountB, uint256 minAmountA, uint256 minAmountB) external;
}

interface IKSP {
    function exchangeKlayPos(address token, uint256 amount, address[] memory path) external payable;
    function exchangeKctPos(address tokenA, uint256 amountA, address tokenB, uint256 amountB, address[] memory path) external;
    function exchangeKlayNeg(address token, uint256 amount, address[] memory path) external payable;
    function exchangeKctNeg(address tokenA, uint256 amountA, address tokenB, uint256 amountB, address[] memory path) external;
    function tokenToPool(address tokenA, address tokenB) external view returns (address);
}
