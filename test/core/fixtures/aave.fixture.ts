import { Contract, Wallet } from 'ethers';
import LendingPool from "../../../build/artifacts/contracts/interfaces/IAaveLendingPool.sol/IAaveLendingPool.json";
import LendingPoolCore from "../../../build/artifacts/contracts/interfaces/IAaveLendingPoolCore.sol/IAaveLendingPoolCore.json";
import { consts } from "../../helpers";


export interface AaveFixture {
  lendingPoolCore: Contract
  lendingPool: Contract
}

export async function aaveFixture(wallet: Wallet): Promise<AaveFixture> {
  const lendingPoolCore = new Contract(consts.AAVE_LENDING_POOL_CORE_ADDRESS, LendingPoolCore.abi, wallet);
  const lendingPool = new Contract(consts.AAVE_LENDING_POOL_ADDRESS, LendingPool.abi, wallet);
  return {
    lendingPoolCore,
    lendingPool
  };
}
