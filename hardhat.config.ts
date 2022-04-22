import '@hardhat-docgen/core'
import '@hardhat-docgen/markdown'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-etherscan'
import '@nomiclabs/hardhat-solhint'
import '@nomiclabs/hardhat-waffle'
import '@openzeppelin/hardhat-upgrades'
import '@typechain/hardhat'
import dotenv from 'dotenv'
import 'hardhat-contract-sizer'
import 'hardhat-deploy'
import 'hardhat-docgen'
import 'hardhat-gas-reporter'
import { HardhatUserConfig } from 'hardhat/config'
import 'solidity-coverage'

dotenv.config()

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      allowUnlimitedContractSize: false,
      forking: {
        url: 'https://data-seed-prebsc-1-s1.binance.org:8545',
        blockNumber: 17444370,
      },
    },
    bsc_testnet: {
      url: 'https://data-seed-prebsc-1-s1.binance.org:8545',
      chainId: 97,
      gasPrice: 20000000000,
    },
    bsc_mainnet: {
      url: 'https://bsc-dataseed.binance.org/',
      chainId: 56,
      gasPrice: 20000000000,
    },
  },
  etherscan: {
    // Your API key for BSCscan
    // Obtain one at https://bscscan.io/
    apiKey: process.env.bscscan_api_key,
  },
  solidity: {
    compilers: [
      {
        version: '0.8.5',
        settings: {
          optimizer: {
            enabled: true,
            runs: 10000,
          },
        },
      },
    ],
  },
  typechain: {
    outDir: './build/typechain/',
    target: 'ethers-v5',
  },
  docgen: {
    path: './docs',
    clear: true,
    runOnCompile: false,
    except: ['/test/*', '/mock/*'],
  },
}

export default config
