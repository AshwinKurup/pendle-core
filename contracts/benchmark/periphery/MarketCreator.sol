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

import "../core/BenchmarkMarket.sol";
import "../interfaces/IBenchmarkProvider.sol";
import "../interfaces/IMarketCreator.sol";
import "../periphery/Utils.sol";

contract MarketCreator is IMarketCreator, Utils {
    address public override factory;
    address private initializer;

    constructor() {
        initializer = msg.sender;
    }

    /**
     * @notice Initializes the BenchmarkFactory.
     * @dev Only called once.
     * @param _factory The address of the BenchmarkFactory core contract.
     **/
    function initialize(address _factory) external {
        require(msg.sender == initializer, "Benchmark: forbidden");
        require(_factory != address(0), "Benchmark: zero address");

        initializer = address(0);
        factory = _factory;
    }

    function create(
        address _xyt,
        address _token,
        ContractDurations _contractDuration,
        uint256 _expiry
    ) external override returns (address market) {
        require(msg.sender == factory, "Benchmark: forbidden");

        market = _create(
            type(BenchmarkMarket).creationCode,
            abi.encodePacked(_xyt, _token, _contractDuration, _expiry),
            abi.encode(_xyt, _token, _contractDuration, _expiry)
        );
    }
}
