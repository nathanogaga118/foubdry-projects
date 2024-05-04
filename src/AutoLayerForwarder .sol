// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import {AggregatorV3Interface} from "../lib/foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AutoLayerPoints} from "./AutoLayerPoints.sol";

import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import './utils/AutoLayerUtils.sol';
import "./interfaces/IParaSwap.sol";
import "./interfaces/IBalancer.sol";

contract AutoLayerForwarder is Ownable {
    using SafeERC20 for IERC20;

    AutoLayerPoints autoLayerPoints;
    AggregatorV3Interface priceFeed;
    address router;
    IBalancer balancerVault;
    address tokenProxy;
    mapping(address => bool) isTokenWhitelisted;
    mapping(address => uint8) public tokenBoost;

    constructor(address autoLayerPointsAddress_, address routerAddress_, address ETHUSDPriceFeedAdress_, address balancerVaultAddress_, address tokenProxyAddress_) Ownable(msg.sender) {
        autoLayerPoints = AutoLayerPoints(autoLayerPointsAddress_);
        priceFeed = AggregatorV3Interface(ETHUSDPriceFeedAdress_);
        router = routerAddress_;
        balancerVault = IBalancer(balancerVaultAddress_);
        tokenProxy = tokenProxyAddress_;
    }

    function swapTokensWithETH(bytes calldata swapData_) external payable returns(uint256 swappedAmount) {
        bytes memory dataWithoutFunctionSelector_ = bytes(swapData_[4:]);
        (Utils.SellData memory sellData_) = abi.decode(dataWithoutFunctionSelector_, (Utils.SellData));

        address toToken_ = address(sellData_.path[sellData_.path.length - 1].to);
        require(sellData_.fromToken != toToken_, "Swapping to same token is not allowed");

        if (sellData_.fromToken == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) require(msg.value == sellData_.fromAmount, "Amount not matching");
        else {
            IERC20(sellData_.fromToken).safeTransferFrom(msg.sender, address(this), sellData_.fromAmount);
            IERC20(sellData_.fromToken).approve(tokenProxy, sellData_.fromAmount);
        }

        uint256 balanceBefore_;
        if (toToken_ != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            balanceBefore_ = IERC20(toToken_).balanceOf(address(this));
        } else balanceBefore_ = address(this).balance;

        (bool success, ) = router.call{value: msg.value}(swapData_);
        require(success, "Swap failed");

        uint256 balanceAfter_;
        if (toToken_ != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) balanceAfter_ = IERC20(toToken_).balanceOf(address(this));
        else balanceAfter_ = address(this).balance;
        swappedAmount = balanceAfter_ - balanceBefore_;

        if(isTokenWhitelisted[toToken_]) {
            uint8 tokenBoost_ = tokenBoost[toToken_];
            addUserPoints(swappedAmount, tokenBoost_);
        }

        if (toToken_ != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) IERC20(toToken_).safeTransfer(msg.sender, swappedAmount);
        else {
            (bool success_, ) = msg.sender.call{value: swappedAmount}("");
            require(success_, "ETH send failed");
        }
    }

    function swapTokens(bytes calldata swapData_) external returns(uint256 swappedAmount) {
        bytes memory dataWithoutFunctionSelector_ = bytes(swapData_[4:]);
        (Utils.SellData memory sellData_) = abi.decode(dataWithoutFunctionSelector_, (Utils.SellData));

        address toToken_ = address(sellData_.path[sellData_.path.length - 1].to);
        require(sellData_.fromToken != toToken_, "Swapping to same token is not allowed");

        IERC20(sellData_.fromToken).safeTransferFrom(msg.sender, address(this), sellData_.fromAmount);
        uint256 balanceBefore_ = IERC20(toToken_).balanceOf(address(this));

        IERC20(sellData_.fromToken).approve(tokenProxy, sellData_.fromAmount);
        (bool success, ) = router.call(swapData_);
        require(success, "Swap failed");
        uint256 balanceAfter_ = IERC20(toToken_).balanceOf(address(this));
        swappedAmount = balanceAfter_ - balanceBefore_;

        if(isTokenWhitelisted[toToken_]) {
            uint8 tokenBoost_ = tokenBoost[toToken_];
            addUserPoints(swappedAmount, tokenBoost_);
        }
        IERC20(toToken_).safeTransfer(msg.sender, swappedAmount);
    }

    function addLiquidityToBalancer(bytes calldata swapData_, address[] memory tokens_, address[] memory tokensWithBpt_, bytes32 poolId_) external payable returns (uint256 bptAmount_){
        (uint256 swappedAmount,, address toToken_) = internalSwap(swapData_);

        address bptAddress = getBptAddress(poolId_);
        uint256[] memory amountsWithBPT = AutoLayerUtils.generateAmounts(swappedAmount, tokensWithBpt_, toToken_);
        uint256[] memory amountsWithoutBPT = AutoLayerUtils.generateAmounts(swappedAmount, tokens_, toToken_);
        bytes memory userDataEncoded_ = abi.encode(1, amountsWithoutBPT);
        JoinPoolRequest memory joinRequest_ = JoinPoolRequest(tokensWithBpt_, amountsWithBPT, userDataEncoded_, false);

        uint256 bptAmountBeforeDeposit_ = IERC20(bptAddress).balanceOf(address(this));
        IERC20(toToken_).approve(address(balancerVault), swappedAmount);
        balancerVault.joinPool(poolId_, address(this), address(this), joinRequest_);
        bptAmount_ = IERC20(bptAddress).balanceOf(address(this)) - bptAmountBeforeDeposit_;

        IERC20(bptAddress).safeTransfer(msg.sender, bptAmount_);
    }

    function removeLiquidityFromBalancer(bytes32 poolId_, address bptToken_, address tokenOut_, address[] memory tokens_, uint256[] memory minAmountsOut_, uint256 bptAmount_) external {
        require(tokens_.length == minAmountsOut_.length, "Not matching lengths");

        IERC20(bptToken_).safeTransferFrom(msg.sender, address(this), bptAmount_);
        IERC20(bptToken_).approve(address(balancerVault), bptAmount_);

        bytes memory userDataEncoded_ = abi.encode(0, bptAmount_, 0);
        IAsset[] memory assets_ = AutoLayerUtils.tokensToAssets(tokens_);
        ExitPoolRequest memory request_ = ExitPoolRequest(assets_, minAmountsOut_, userDataEncoded_, false);

        uint256 balanceBefore_ = IERC20(tokenOut_).balanceOf(address(this));
        balancerVault.exitPool(poolId_, address(this), payable(address(this)), request_);
        uint256 balanceAfter_ = IERC20(tokenOut_).balanceOf(address(this));

        IERC20(tokenOut_).safeTransfer(msg.sender, balanceAfter_ - balanceBefore_);
    }

    function internalSwap(bytes calldata swapData_) internal returns(uint256 swappedAmount, address fromToken, address toToken) {
        bytes memory dataWithoutFunctionSelector_ = bytes(swapData_[4:]);
        (Utils.SellData memory sellData_) = abi.decode(dataWithoutFunctionSelector_, (Utils.SellData));

        fromToken = sellData_.fromToken;
        toToken = address(sellData_.path[sellData_.path.length - 1].to);

        require(fromToken != toToken, "Swapping to same token is not allowed");
        if (fromToken == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) require(msg.value == sellData_.fromAmount, "Amount not matching");
        else {
            IERC20(fromToken).safeTransferFrom(msg.sender, address(this), sellData_.fromAmount);
            IERC20(fromToken).approve(tokenProxy, sellData_.fromAmount);
        }

        uint256 balanceBefore_;
        if (toToken != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            balanceBefore_ = IERC20(toToken).balanceOf(address(this));
        } else balanceBefore_ = address(this).balance;

        (bool success, ) = router.call{value: msg.value}(swapData_);
        require(success, "Swap failed");

        uint256 balanceAfter_;
        if (toToken != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) balanceAfter_ = IERC20(toToken).balanceOf(address(this));
        else balanceAfter_ = address(this).balance;
        swappedAmount = balanceAfter_ - balanceBefore_;

        if(isTokenWhitelisted[toToken]) {
            uint8 tokenBoost_ = tokenBoost[toToken];
            addUserPoints(swappedAmount, tokenBoost_);
        }
    }

    function getBptAddress(bytes32 poolId_) public view returns(address bptAddress) {
        (bptAddress, ) = balancerVault.getPool(poolId_);
    }


    function addUserPoints(uint256 ETHAmount_, uint8 tokenBoost_) internal {
        uint256 ETHCurrentPrice = retrieveETHPrice() / (10 ** priceFeed.decimals());
        uint256 points = ETHAmount_ * ETHCurrentPrice;
        autoLayerPoints.addPoints(msg.sender, points * tokenBoost_);
    }

    function retrieveETHPrice() internal view returns(uint256 answer_) {
       (, int answer,,,) = priceFeed.latestRoundData();

       if (answer < 0) return 0;
       else return uint256(answer);
    }

    function whitelistTokens(address[] memory tokenAddresses_) external onlyOwner() {
        for (uint8 i; i < tokenAddresses_.length; i++) {
            isTokenWhitelisted[tokenAddresses_[i]] = true;
            tokenBoost[tokenAddresses_[i]] = 1;
        }
    }

    function blackListTokens(address[] memory tokenAddresses_) external onlyOwner() {
        for (uint8 i; i < tokenAddresses_.length; i++) {
            isTokenWhitelisted[tokenAddresses_[i]] = false;
        }
    }

    function changeTokenBoost(address tokenAddress_, uint8 newBoost) external onlyOwner() {
        require(isTokenWhitelisted[tokenAddress_], "Token is not whitelisted");
        tokenBoost[tokenAddress_] = newBoost;
    }

    receive() external virtual payable {

    }

}
