// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

abstract contract IController {
    function supportTarget(address _target, bool _support) virtual external;
}