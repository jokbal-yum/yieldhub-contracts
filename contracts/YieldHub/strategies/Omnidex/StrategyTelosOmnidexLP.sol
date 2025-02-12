// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/omnidex/IOmnidexRouter01.sol";
import "../../interfaces/omnidex/IOmnidexPair.sol";
import "../../interfaces/omnidex/IZenMaster.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";

contract StrategyTelosOmnidexLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public native;

    address public output;

    address public want;

    address public lpToken0;
    
    address public lpToken1;

    address public chef;

    uint256 public poolId;

    uint256 public lastHarvest;

    bool public harvestOnDeposit;

    address[] public outputToNativeRoute;

    address[] public nativeToOutputRoute;

    address[] public outputToLp0Route;

    address[] public outputToLp1Route;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    
    event Deposit(uint256 tvl);
    
    event Withdraw(uint256 tvl);

    constructor(
        address _want,

        uint256 _poolId,

        address _chef,

        address _vault,

        address _unirouter,

        address _keeper,

        address _strategist,

        address _yieldhubFeeRecipient,

        address[] memory _outputToNativeRoute,

        address[] memory _outputToLp0Route,

        address[] memory _outputToLp1Route
    ) public StratManager(_keeper, _strategist, _unirouter, _vault, _yieldhubFeeRecipient) {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        require(_outputToNativeRoute.length >= 2, "need output to native");
        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;
        
        // setup lp routing
        lpToken0 = IOmnidexPair(want).token0();
        require(_outputToLp0Route[0] == output, "first != output");
        require(_outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0, "last != lptoken0");
        outputToLp0Route = _outputToLp0Route;

        lpToken1 = IOmnidexPair(want).token1();
        require(_outputToLp1Route[0] == output, "first != output");
        require(_outputToLp1Route[_outputToLp1Route.length - 1] == lpToken1, "last != lptoken1");
        outputToLp1Route = _outputToLp1Route;

        nativeToOutputRoute = new address[](_outputToNativeRoute.length);
        for (uint i = 0; i < _outputToNativeRoute.length; i++) {
            uint idx = _outputToNativeRoute.length - 1 - i;
            nativeToOutputRoute[i] = outputToNativeRoute[idx];
        }
        // set allowances to max for all possible approvals
        _giveAllowances();
    }

    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal > 0) {
            IZenMaster(chef).deposit(poolId, wantBal);            
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IZenMaster(chef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);
        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IZenMaster(chef).deposit(poolId, 0);
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();
            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    function chargeFees(address callFeeRecipient) internal {
        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);

        IOmnidexRouter01(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), now);

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 yieldhubFeeAmount = nativeBal.mul(yieldhubFee).div(MAX_FEE);
        IERC20(native).safeTransfer(yieldhubFeeRecipient, yieldhubFeeAmount);

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    function addLiquidity() internal {

        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            IOmnidexRouter01(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), now);
        }

        if (lpToken1 != output) {
            IOmnidexRouter01(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), now);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));

        IOmnidexRouter01(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now);
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IZenMaster(chef).userInfo(poolId, address(this));	
        return _amount;
    }

    function rewardsAvailable() public view returns (uint256) {
        return IZenMaster(chef).pendingCharm(poolId, address(this));
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IZenMaster(chef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    function panic() public onlyManager {
        pause();
        IZenMaster(chef).emergencyWithdraw(poolId);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));
        IERC20(native).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(native).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }

    function nativeToOutput() external view returns (address[] memory) {
        return nativeToOutputRoute;
    }

    function outputToLp0() external view returns (address[] memory) {
        return outputToLp0Route;
    }

    function outputToLp1() external view returns (address[] memory) {
        return outputToLp1Route;
    }
}
