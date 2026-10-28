# Searching Token Jars

The searcher guide lives in the Uniswap developer docs.

- **[Search Token Jars](https://developers.uniswap.org/docs/protocols/tjar/guides/search-token-jars)** covers finding jars, pricing their contents, making a release, and every revert.
- **[Deployments](https://developers.uniswap.org/docs/protocols/tjar/deployments)** lists the Factory and Fee Controller on each supported chain.
- **[TJAR Overview](https://developers.uniswap.org/docs/protocols/tjar/overview)** explains how the jar, releaser, and Fee Controller fit together.

## Source

The releaser interface is [`IReleaser.sol`](src/interfaces/IReleaser.sol) and the jar is [`TokenJar.sol`](src/TokenJar.sol). Audit reports are in [`audit/`](audit/).

Security issues go to security@uniswap.org. Everything else, open an issue.
