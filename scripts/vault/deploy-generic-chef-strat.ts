import hardhat, { ethers, web3 } from "hardhat";
import { predictAddresses } from "../../utils/predictAddresses";

const vaultParams = {
  name: "omnidex-dmmy-karma",
  symbol: "yhDmmyKarma",
  delay: 21600,
};

const strategyParams = {
  want:"0x76Bf9208b92C75c94A5723f4a7343C26BB5739B8",
  poolId: 29,
  chef: "0x79f5A8BD0d6a00A41EA62cdA426CEf0115117a61",
  unirouter: "0xF9678db1CE83f6f51E5df348E2Cc842Ca51EfEc1",
  strategist: "0xeD6d4e2D263334829954D880BF6A366834410713", // some address
  keeper: "0xeD6d4e2D263334829954D880BF6A366834410713",
  beefyFeeRecipient: "0xeD6d4e2D263334829954D880BF6A366834410713",
  outputToNativeRoute: ["0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df", "0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E"],
  outputToLp0Route: ["0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df", "0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E", "0x2f15F85a6c346C0a2514Af70075259e503E7137B"],
  outputToLp1Route: ["0xd2504a02fABd7E546e41aD39597c377cA8B0E1Df", "0x730d2Fa7dC7642E041bcE231E85b39e9bF4a6a64"],
 // pendingRewardsFunctionName: "pendingTri", // used for rewardsAvailable(), use correct function name from masterchef
};

const contractNames = {
  vault: "YieldHubVaultV6",
  strategy: "StrategyTelosOmnidexLP",
};

async function main() {
  if (
    Object.values(vaultParams).some(v => v === undefined) ||
    Object.values(strategyParams).some(v => v === undefined) ||
    Object.values(contractNames).some(v => v === undefined)
  ) {
    console.error("one of config values undefined");
    return;
  }

  await hardhat.run("compile");

  const Vault = await ethers.getContractFactory(contractNames.vault);
  const Strategy = await ethers.getContractFactory(contractNames.strategy);

  const [deployer] = await ethers.getSigners();

  console.log("Deploying:", vaultParams.name);

  const predictedAddresses = await predictAddresses({ creator: deployer.address });

  const vaultConstructorArguments = [
    predictedAddresses.strategy,
    vaultParams.name,
    vaultParams.symbol,
    vaultParams.delay,
  ];
  const vault = await Vault.deploy(...vaultConstructorArguments);
  await vault.deployed();

  const strategyConstructorArguments = [
    strategyParams.want,
    strategyParams.poolId,
    strategyParams.chef,
    vault.address,
    strategyParams.unirouter,
    strategyParams.keeper,
    strategyParams.strategist,
    strategyParams.beefyFeeRecipient,
    strategyParams.outputToNativeRoute,
    strategyParams.outputToLp0Route,
    strategyParams.outputToLp1Route,
  ];
  const strategy = await Strategy.deploy(...strategyConstructorArguments);
  await strategy.deployed();

  // add this info to PR
  console.log("Vault:", vault.address);
  console.log("Strategy:", strategy.address);
  console.log("Want:", strategyParams.want);
  console.log("PoolId:", strategyParams.poolId);

  console.log();
  console.log("Running post deployment");

  const verifyContractsPromises: Promise<any>[] = [];

  await Promise.all(verifyContractsPromises);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });