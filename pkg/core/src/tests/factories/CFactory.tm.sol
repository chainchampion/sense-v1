// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

// Internal references
import { FixedMath } from "../../external/FixedMath.sol";
import { CAdapter } from "../../adapters/compound/CAdapter.sol";
import { CFactory } from "../../adapters/compound/CFactory.sol";
import { BaseFactory } from "../../adapters/BaseFactory.sol";
import { Divider, TokenHandler } from "../../Divider.sol";

import { DSTest } from "../test-helpers/test.sol";
import { Hevm } from "../test-helpers/Hevm.sol";
import { DateTimeFull } from "../test-helpers/DateTimeFull.sol";
import { User } from "../test-helpers/User.sol";
import { Assets } from "../test-helpers/Assets.sol";
import { Errors } from "@sense-finance/v1-utils/src/libs/Errors.sol";

contract CAdapterTestHelper is DSTest {
    using FixedMath for uint256;

    CFactory internal factory;
    Divider internal divider;
    TokenHandler internal tokenHandler;

    uint16 public constant MODE = 0;
    uint64 public constant ISSUANCE_FEE = 0.01e18;
    uint256 public constant STAKE_SIZE = 1e18;
    uint256 public constant MIN_MATURITY = 2 weeks;
    uint256 public constant MAX_MATURITY = 14 weeks;
    uint256 public DEFAULT_TS = FixedMath.WAD.fdiv(FixedMath.WAD * 31622400); // 1 / 1 year in seconds;
    uint256 public DEFAULT_G1 = (FixedMath.WAD * 950).fdiv(FixedMath.WAD * 1000); // 0.95 for selling underlying
    uint256 public DEFAULT_G2 = (FixedMath.WAD * 1000).fdiv(FixedMath.WAD * 950); // 1 / 0.95 for selling PT

    function setUp() public {
        tokenHandler = new TokenHandler();
        divider = new Divider(address(this), address(tokenHandler));
        tokenHandler.init(address(divider));

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = Assets.COMP;

        // deploy compound adapter factory
        BaseFactory.FactoryParams memory factoryParams = BaseFactory.FactoryParams({
            stake: Assets.DAI,
            oracle: Assets.RARI_ORACLE,
            ifee: ISSUANCE_FEE,
            stakeSize: STAKE_SIZE,
            minm: MIN_MATURITY,
            maxm: MAX_MATURITY,
            mode: MODE,
            tilt: 0,
            ts: DEFAULT_TS,
            g1: DEFAULT_G1,
            g2: DEFAULT_G2,
            oracleEnabled: true
        });
        factory = new CFactory(address(divider), factoryParams, Assets.COMP);
        divider.setIsTrusted(address(factory), true); // add factory as a ward
    }
}

contract CFactories is CAdapterTestHelper {
    function testMainnetDeployFactory() public {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = Assets.COMP;

        BaseFactory.FactoryParams memory factoryParams = BaseFactory.FactoryParams({
            stake: Assets.DAI,
            oracle: Assets.RARI_ORACLE,
            ifee: ISSUANCE_FEE,
            stakeSize: STAKE_SIZE,
            minm: MIN_MATURITY,
            maxm: MAX_MATURITY,
            mode: MODE,
            tilt: 0,
            ts: DEFAULT_TS,
            g1: DEFAULT_G1,
            g2: DEFAULT_G2,
            oracleEnabled: true
        });
        CFactory otherCFactory = new CFactory(address(divider), factoryParams, Assets.COMP);

        assertTrue(address(otherCFactory) != address(0));
        (
            address oracle,
            address stake,
            uint256 stakeSize,
            uint256 minm,
            uint256 maxm,
            uint256 ifee,
            uint16 mode,
            uint64 tilt,
            uint256 ts,
            uint256 g1,
            uint256 g2,
            bool oracleEnabled
        ) = CFactory(otherCFactory).factoryParams();

        assertEq(CFactory(otherCFactory).divider(), address(divider));
        // assertEq(CFactory(otherCFactory).rewardTokens(0), Assets.COMP); //TODO: remove line, factoriess do not have reward tokens
        assertEq(stake, Assets.DAI);
        assertEq(ifee, ISSUANCE_FEE);
        assertEq(stakeSize, STAKE_SIZE);
        assertEq(minm, MIN_MATURITY);
        assertEq(maxm, MAX_MATURITY);
        assertEq(mode, MODE);
        assertEq(oracle, Assets.RARI_ORACLE);
        assertEq(tilt, 0);
        assertEq(ts, DEFAULT_TS);
        assertEq(g1, DEFAULT_G1);
        assertEq(g2, DEFAULT_G2);
        assertTrue(oracleEnabled);
    }

    function testMainnetDeployAdapter() public {
        divider.setPeriphery(address(this));
        address f = factory.deployAdapter(Assets.cDAI, "");
        CAdapter adapter = CAdapter(payable(f));
        assertTrue(address(adapter) != address(0));
        assertEq(CAdapter(adapter).target(), address(Assets.cDAI));
        assertEq(CAdapter(adapter).divider(), address(divider));
        assertEq(CAdapter(adapter).name(), "Compound Dai Adapter");
        assertEq(CAdapter(adapter).symbol(), "cDAI-adapter");

        uint256 scale = CAdapter(adapter).scale();
        assertTrue(scale > 0);
    }

    function testMainnetCantDeployAdapterIfNotSupportedTarget() public {
        divider.setPeriphery(address(this));
        try factory.deployAdapter(Assets.f18DAI, "") {
            fail();
        } catch (bytes memory error) {
            assertEq0(error, abi.encodeWithSelector(Errors.TargetNotSupported.selector));
        }
    }
}
