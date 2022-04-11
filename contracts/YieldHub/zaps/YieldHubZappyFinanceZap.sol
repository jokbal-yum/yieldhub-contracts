// SPDX-License-Identifier: GPLv2

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// @author Wivern for Beefy.Finance
// @notice This contract adds liquidity to Zappy compatible liquidity pair pools and stake.

pragma solidity ^0.6.8;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@uniswap/lib/contracts/libraries/Babylonian.sol";
import "../interfaces/zappy/IUniswapV2Pair.sol";
import "../interfaces/zappy/IUniswapV2Router01.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IYieldHubVault is IERC20 {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function want() external pure returns (address); // Beefy Vault V6
    function token() external pure returns (address); // Beefy Vault V5
}

contract YieldHubZappyFinanceZap {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IYieldHubVault;

    IUniswapV2Router01 public immutable router;
    address public immutable WETH;
    uint256 public constant minimumAmount = 1000;

    constructor(address _router, address _WETH) public {
        // Safety checks to ensure WETH token address
        IWETH(_WETH).deposit{value: 0}();
        IWETH(_WETH).withdraw(0);

        router = IUniswapV2Router01(_router);
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH);
    }

    function yhInETH (address yieldhubVault, uint256 tokenAmountOutMin) external payable {
        require(msg.value >= minimumAmount, "YieldHub: Insignificant input amount");

        IWETH(WETH).deposit{value: msg.value}();

        _swapAndStake(yieldhubVault, tokenAmountOutMin, WETH);
    }

    function yieldhubIn (address yieldhubVault, uint256 tokenAmountOutMin, address tokenIn, uint256 tokenInAmount) external {
        require(tokenInAmount >= minimumAmount, "YieldHub: Insignificant input amount");
        require(IERC20(tokenIn).allowance(msg.sender, address(this)) >= tokenInAmount, "YieldHub: Input token is not approved");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), tokenInAmount);

        _swapAndStake(yieldhubVault, tokenAmountOutMin, tokenIn);
    }

    function yieldhubOut (address yieldhubVault, uint256 withdrawAmount) external {
        (IYieldHubVault vault, IUniswapV2Pair pair) = _getVaultPair(yieldhubVault);

        IERC20(yieldhubVault).safeTransferFrom(msg.sender, address(this), withdrawAmount);
        vault.withdraw(withdrawAmount);

        if (pair.token0() != WETH && pair.token1() != WETH) {
            return _removeLiquidity(address(pair), msg.sender);
        }

        _removeLiquidity(address(pair), address(this));

        address[] memory tokens = new address[](2);
        tokens[0] = pair.token0();
        tokens[1] = pair.token1();

        _returnAssets(tokens);
    }

    function yieldhubOutAndSwap(address yieldhubVault, uint256 withdrawAmount, address desiredToken, uint256 desiredTokenOutMin) external {
        (IYieldHubVault vault, IUniswapV2Pair pair) = _getVaultPair(yieldhubVault);
        address token0 = pair.token0();
        address token1 = pair.token1();
        require(token0 == desiredToken || token1 == desiredToken, "YieldHub: desired token not present in liquidity pair");

        vault.safeTransferFrom(msg.sender, address(this), withdrawAmount);
        vault.withdraw(withdrawAmount);
        _removeLiquidity(address(pair), address(this));

        address swapToken = token1 == desiredToken ? token0 : token1;
        address[] memory path = new address[](2);
        path[0] = swapToken;
        path[1] = desiredToken;

        _approveTokenIfNeeded(path[0], address(router));
        router.swapExactTokensForTokens(IERC20(swapToken).balanceOf(address(this)), desiredTokenOutMin, path, address(this), block.timestamp);

        _returnAssets(path);
    }

    function _removeLiquidity(address pair, address to) private {
        IERC20(pair).safeTransfer(pair, IERC20(pair).balanceOf(address(this)));
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);

        require(amount0 >= minimumAmount, "UniswapV2Router01: INSUFFICIENT_A_AMOUNT");
        require(amount1 >= minimumAmount, "UniswapV2Router01: INSUFFICIENT_B_AMOUNT");
    }

    function _getVaultPair (address yieldhubVault) private view returns (IYieldHubVault vault, IUniswapV2Pair pair) {
        vault = IYieldHubVault(yieldhubVault);

        try vault.want() returns (address pairAddress) {
            pair = IUniswapV2Pair(pairAddress); // Vault V6
        } catch {
            pair = IUniswapV2Pair(vault.token()); // Vault V5
        }

        require(pair.factory() == router.factory(), "YieldHub: Incompatible liquidity pair factory");
    }

    function _swapAndStake(address yieldhubVault, uint256 tokenAmountOutMin, address tokenIn) private {
        (IYieldHubVault vault, IUniswapV2Pair pair) = _getVaultPair(yieldhubVault);

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        require(reserveA > minimumAmount && reserveB > minimumAmount, "YieldHub: Liquidity pair reserves too low");

        bool isInputA = pair.token0() == tokenIn;
        require(isInputA || pair.token1() == tokenIn, "YieldHub: Input token not present in liquidity pair");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = isInputA ? pair.token1() : pair.token0();

        uint256 fullInvestment = IERC20(tokenIn).balanceOf(address(this));
        uint256 swapAmountIn;
        if (isInputA) {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveA, reserveB, path[0], path[1]);
        } else {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveB, reserveA, path[0], path[1]);
        }

        _approveTokenIfNeeded(path[0], address(router));
        uint256[] memory swapedAmounts = router
            .swapExactTokensForTokens(swapAmountIn, tokenAmountOutMin, path, address(this), block.timestamp);

        _approveTokenIfNeeded(path[1], address(router));
        (,, uint256 amountLiquidity) = router
            .addLiquidity(path[0], path[1], fullInvestment.sub(swapedAmounts[0]), swapedAmounts[1], 1, 1, address(this), block.timestamp);

        _approveTokenIfNeeded(address(pair), address(vault));
        vault.deposit(amountLiquidity);

        vault.safeTransfer(msg.sender, vault.balanceOf(address(this)));
        _returnAssets(path);
    }

    function _returnAssets(address[] memory tokens) private {
        uint256 balance;
        for (uint256 i; i < tokens.length; i++) {
            balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                if (tokens[i] == WETH) {
                    IWETH(WETH).withdraw(balance);
                    (bool success,) = msg.sender.call{value: balance}(new bytes(0));
                    require(success, "YieldHub: ETH transfer failed");
                } else {
                    IERC20(tokens[i]).safeTransfer(msg.sender, balance);
                }
            }
        }
    }

    function _getSwapAmount(uint256 investmentA, uint256 reserveA, uint256 reserveB, address token0, address token1) private view returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA / 2;
        uint256 nominator = router.getAmountOut(halfInvestment, reserveA, reserveB);
        uint256 denominator = router.quote(halfInvestment, reserveA.add(halfInvestment), reserveB.sub(nominator));
        swapAmount = investmentA.sub(Babylonian.sqrt(halfInvestment * halfInvestment * nominator / denominator));
    }

    function estimateSwap(address yieldhubVault, address tokenIn, uint256 fullInvestmentIn) public view returns(uint256 swapAmountIn, uint256 swapAmountOut, address swapTokenOut) {
        (, IUniswapV2Pair pair) = _getVaultPair(yieldhubVault);

        bool isInputA = pair.token0() == tokenIn;
        require(isInputA || pair.token1() == tokenIn, "YieldHub: Input token not present in liquidity pair");

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        (reserveA, reserveB) = isInputA ? (reserveA, reserveB) : (reserveB, reserveA);

        swapTokenOut = isInputA ? pair.token1() : pair.token0();
        swapAmountIn = _getSwapAmount(fullInvestmentIn, reserveA, reserveB, tokenIn, swapTokenOut);
        swapAmountOut = router.getAmountOut(swapAmountIn, reserveA, reserveB);
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, type(uint256).max);
        }
    }

}
