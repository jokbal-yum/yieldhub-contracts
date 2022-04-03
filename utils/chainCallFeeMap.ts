import { YieldHubChain } from "./yieldhubChain"

const defaultFee = 111;
const reducedFee = 11;

export const chainCallFeeMap: Record<YieldHubChain, number> = {
  telos: reducedFee,
};
