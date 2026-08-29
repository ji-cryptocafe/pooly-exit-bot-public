export const EXITOR_ABI = [
  { type: 'function', name: 'available', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'preview', stateMutability: 'view', inputs: [],
    outputs: [{ name: 'avail', type: 'uint256' }, { name: 'sharesLeft', type: 'uint256' }] },
  { type: 'function', name: 'grab', stateMutability: 'nonpayable',
    inputs: [{ name: 'minAssets', type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'OWNER', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'RECEIVER', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'VAULT', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'ASSET', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'MIN_RATE_BPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'event', name: 'Grabbed', inputs: [
    { name: 'assets', type: 'uint256', indexed: false },
    { name: 'shares', type: 'uint256', indexed: false },
    { name: 'sharesLeft', type: 'uint256', indexed: false } ] },
];

export const MTOKEN_ABI = [
  { type: 'function', name: 'getCash', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];

export const ERC20_ABI = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
];
