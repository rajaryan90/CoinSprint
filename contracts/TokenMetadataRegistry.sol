// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreatorCheck {
    function creator() external view returns (address);
}

/**
 * @title TokenMetadataRegistry
 * @notice Optional image/social metadata for tokens launched through
 *         LaunchpadFactory, kept in a completely separate contract on
 *         purpose. MemecoinBondingCurve and LaunchpadFactory are the
 *         money-handling contracts — they're done, tested hard, and
 *         adding cosmetic fields to them would mean re-touching and
 *         re-testing logic that currently has no reason to change. This
 *         registry can be redeployed, extended, or replaced independently
 *         without touching a single line of the financial contracts.
 *
 * Anyone can call setMetadata for a token, but only that token's actual
 * creator's write takes effect — enforced by reading creator() directly
 * off the token contract, not by trusting a claim. Metadata is mutable
 * (a creator can update their token's image/links later), unlike
 * everything in the core contracts, which is deliberately immutable —
 * cosmetic data and financial logic have different correctness
 * requirements, so they get different mutability rules.
 */
contract TokenMetadataRegistry {
    struct Metadata {
        string imageUrl;
        string twitter;
        string telegram;
        string website;
        string description;
        bool isSet;
    }

    uint256 public constant MAX_URL_LENGTH = 300;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 500;

    mapping(address => Metadata) public metadata;

    event MetadataUpdated(address indexed token, address indexed creator);

    function setMetadata(
        address token,
        string calldata imageUrl,
        string calldata twitter,
        string calldata telegram,
        string calldata website,
        string calldata description
    ) external {
        require(ICreatorCheck(token).creator() == msg.sender, "only the token's creator can set its metadata");
        require(bytes(imageUrl).length <= MAX_URL_LENGTH, "imageUrl too long");
        require(bytes(twitter).length <= MAX_URL_LENGTH, "twitter too long");
        require(bytes(telegram).length <= MAX_URL_LENGTH, "telegram too long");
        require(bytes(website).length <= MAX_URL_LENGTH, "website too long");
        require(bytes(description).length <= MAX_DESCRIPTION_LENGTH, "description too long");

        metadata[token] = Metadata(imageUrl, twitter, telegram, website, description, true);
        emit MetadataUpdated(token, msg.sender);
    }

    function getMetadata(address token) external view returns (Metadata memory) {
        return metadata[token];
    }
}
