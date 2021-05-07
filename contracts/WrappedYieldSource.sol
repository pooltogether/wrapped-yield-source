/// SPDX-License-Identifier: GPL-V3

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import "@pooltogether/fixed-point/contracts/FixedPoint.sol";

import "./external/IYieldSource.sol";

/// @title Wraps a yield source with functionality that batches deposits and captures reserve.
contract WrappedYieldSource is OwnableUpgradeable, ERC20Upgradeable, IYieldSource {
  using SafeMathUpgradeable for uint256;
  using SafeCastUpgradeable for uint256;
  using SafeERC20Upgradeable for IERC20Upgradeable;

  IYieldSource public yieldSource;
  uint128 public pendingReserve;
  uint128 public lastExchangeRateMantissa;
  uint128 public reserveRateMantissa;

  function initialize(IYieldSource _yieldSource, string memory name_, string memory symbol_) public initializer {
    __ERC20_init(name_, symbol_);
    __Ownable_init();
    yieldSource = _yieldSource;
  }

  /// @notice Returns the ERC20 asset token used for deposits.
  /// @return The ERC20 asset token
  function depositToken() external override view returns (address) {
    return yieldSource.depositToken();
  }

  /// @notice Returns the total balance (in asset tokens).  This includes the deposits and interest.
  /// @return The underlying balance of asset tokens
  function balanceOfToken(address addr) external override returns (uint256) {
    _captureReserve();
    return _sharesToTokens(balanceOf(addr));
  }

  /// @notice Supplies tokens to the yield source.  Allows assets to be supplied on other user's behalf using the `to` param.
  /// @param amount The amount of `token()` to be supplied
  /// @param to The user whose balance will receive the tokens
  function supplyTokenTo(uint256 amount, address to) external override {
    _captureReserve();
    _mint(to, _tokensToShares(amount));
    IERC20Upgradeable(yieldSource.depositToken()).safeTransferFrom(to, address(this), amount);
  }

  /// @notice Redeems tokens from the yield source.
  /// @param _tokens The amount of `token()` to withdraw.  Denominated in `token()` as above.
  /// @return The actual amount of tokens that were redeemed.
  function redeemToken(uint256 _tokens) external override returns (uint256) {
    _captureReserve();
    uint256 _share = _tokensToShares(_tokens);
    _burn(msg.sender, _share);
    IERC20Upgradeable _token = IERC20Upgradeable(yieldSource.depositToken());

    uint256 balance = _token.balanceOf(address(this));
    uint256 less;
    if (balance < _tokens) {
      uint256 additionalBalanceRequired = _tokens.sub(balance);
      uint256 actuallyWithdrawn = yieldSource.redeemToken(additionalBalanceRequired);
      less = additionalBalanceRequired.sub(actuallyWithdrawn);
    }

    uint256 amount = _tokens.sub(less);

    _token.transfer(msg.sender, _tokens.sub(less));

    return amount;
  }

  function tokensToShares(uint256 tokens) external returns (uint256) {
    _captureReserve();
    return _tokensToShares(tokens);
  }

  function _tokensToShares(uint256 tokens) internal returns (uint256) {
    uint256 totalTokens = yieldSource.balanceOfToken(address(this)).sub(pendingReserve);
    uint256 totalShares = totalSupply();
    if (totalShares == 0 || totalTokens == 0) {
      return tokens;
    } else {
      return tokens.mul(totalShares).div(totalTokens);
    }
  }

  function mintReserve() external returns (bool) {
    _captureReserve();
    _mint(owner(), _tokensToShares(pendingReserve));
    pendingReserve = 0;

    return true;
  }

  function batch() external returns (bool) {
    IERC20Upgradeable _token = IERC20Upgradeable(yieldSource.depositToken());
    uint256 balance = _token.balanceOf(address(this));
    _token.approve(address(yieldSource), balance);
    yieldSource.supplyTokenTo(balance, address(this));

    return true;
  }

  function sharesToTokens(uint256 _share) external returns (uint256) {
    _captureReserve();
    return _sharesToTokens(_share);
  }

  function _sharesToTokens(uint256 _share) internal returns (uint256) {
    uint256 totalShares = totalSupply();
    return _share.mul(yieldSource.balanceOfToken(address(this)).sub(pendingReserve)).div(totalShares);
  }

  function _captureReserve() internal {
    uint256 currentExchangeRateMantissa;
    uint256 _lastExchangeRateMantissa = lastExchangeRateMantissa;
    uint256 _supply = totalSupply();
    if (_supply > 0) {
      currentExchangeRateMantissa = FixedPoint.calculateMantissa(yieldSource.balanceOfToken(address(this)), _supply);
    }
    if (_lastExchangeRateMantissa == 0) {
      _lastExchangeRateMantissa = currentExchangeRateMantissa;
    }
    uint256 differenceMantissa;
    uint256 accruedReserve;
    if (currentExchangeRateMantissa > _lastExchangeRateMantissa) {
      differenceMantissa = currentExchangeRateMantissa.sub(_lastExchangeRateMantissa);
      uint256 reservePortionMantissa = FixedPoint.multiplyUintByMantissa(differenceMantissa, reserveRateMantissa);
      accruedReserve = FixedPoint.multiplyUintByMantissa(_supply, reservePortionMantissa).toUint128();
    }

    lastExchangeRateMantissa = currentExchangeRateMantissa.toUint128();
    pendingReserve = uint256(pendingReserve).add(accruedReserve).toUint128();
  }
}
