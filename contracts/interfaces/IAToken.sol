// SPDX-License-Identifier: MIT
/*
 * MIT License
 * ===========
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 */
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title Aave ERC20 AToken
 *
 * @dev Implementation of the interest bearing token for the DLP protocol.
 * @author Aave
 */
interface IAToken is IERC20 {
    /**
     * @dev gives allowance to an address to execute the interest redirection
     * on behalf of the caller.
     * @param _to the address to which the interest will be redirected. Pass address(0) to reset
     * the allowance.
     **/
    function allowInterestRedirectionTo(address _to) external;

    /**
     * @dev calculates the balance of the user, which is the
     * principal balance + interest generated by the principal balance + interest
     * generated by the redirected balance
     * @param _user the user for which the balance is being calculated
     * @return the total balance of the user
     **/
    /* function balanceOf(address _user) external view returns (uint256); */

    /**
    * @dev returns the last index of the user, used to calculate the balance of the user
    * @param _user address of the user
    * @return the last user index
    **/
    function getUserIndex(address _user) external view returns(uint256);

    /**
    * @dev returns the address to which the interest is redirected
    * @param _user address of the user
    * @return 0 if there is no redirection, an address otherwise
    **/
    function getInterestRedirectionAddress(address _user) external view returns(address);

    /**
    * @dev returns the redirected balance of the user. The redirected balance is the balance
    * redirected by other accounts to the user, that is accrueing interest for him.
    * @param _user address of the user
    * @return the total redirected balance
    **/
    function getRedirectedBalance(address _user) external view returns(uint256);

    /**
     * @dev returns the principal balance of the user. The principal balance is the last
     * updated stored balance, which does not consider the perpetually accruing interest.
     * @param _user the address of the user
     * @return the principal balance of the user
     **/
    function principalBalanceOf(address _user) external view returns (uint256);

    /**
     * @dev redirects the interest generated to a target address.
     * when the interest is redirected, the user balance is added to
     * the recepient redirected balance.
     * @param _to the address to which the interest will be redirected
     **/
    function redirectInterestStream(address _to) external;

    /**
     * @dev redirects the interest generated by _from to a target address.
     * when the interest is redirected, the user balance is added to
     * the recepient redirected balance. The caller needs to have allowance on
     * the interest redirection to be able to execute the function.
     * @param _from the address of the user whom interest is being redirected
     * @param _to the address to which the interest will be redirected
     **/
    function redirectInterestStreamOf(address _from, address _to) external;

    /**
     * @dev redeems aToken for the underlying asset
     * @param _amount the amount being redeemed
     **/
    function redeem(uint256 _amount) external;
}
