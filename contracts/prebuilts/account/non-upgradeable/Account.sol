// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable reason-string */

// Base
import "../utils/BaseAccount.sol";

// Extensions
import "../utils/AccountCore.sol";
import "../../../extension/upgradeable/ContractMetadata.sol";
import "../../../external-deps/openzeppelin/token/ERC721/utils/ERC721Holder.sol";
import "../../../external-deps/openzeppelin/token/ERC1155/utils/ERC1155Holder.sol";

// Utils
import "../../../eip/ERC1271.sol";
import "../utils/Helpers.sol";
import "../../../external-deps/openzeppelin/utils/cryptography/ECDSA.sol";
import "../utils/BaseAccountFactory.sol";

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

contract Account is AccountCore, ContractMetadata, ERC1271, ERC721Holder, ERC1155Holder {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 private constant MSG_TYPEHASH = keccak256("AccountMessage(bytes message)");

    /*///////////////////////////////////////////////////////////////
                    Constructor, Initializer, Modifiers
    //////////////////////////////////////////////////////////////*/

    constructor(IEntryPoint _entrypoint, address _factory) AccountCore(_entrypoint, _factory) {}

    /// @notice Checks whether the caller is the EntryPoint contract or the admin.
    modifier onlyAdminOrEntrypoint() virtual {
        require(msg.sender == address(entryPoint()) || isAdmin(msg.sender), "Account: not admin or EntryPoint.");
        _;
    }

    /// @notice Lets the account receive native tokens.
    receive() external payable {}

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155Receiver) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice See EIP-1271
    function isValidSignature(
        bytes32 _message,
        bytes memory _signature
    ) public view virtual override returns (bytes4 magicValue) {
        bytes32 digest;
        bytes memory targetSig;

        // Handle OpenSea bulk order signatures that are >65 bytes in length.
        if (_signature.length > 65) {
            // We decode the received bytes data into:
            // 1. abi encode-packed signature
            // 2. target digest that was signed to produce the signature
            (bytes memory extractedPackedSig, bytes32 bulkOrderDigest) = abi.decode(_signature, (bytes, bytes32));

            // Use the modified digest built for bulk orders
            digest = bulkOrderDigest;

            // Extract the signature, which is the first 65 bytes
            targetSig = new bytes(65);
            for (uint i = 0; i < 65; i++) {
                targetSig[i] = extractedPackedSig[i];
            }
        } else {
            digest = getMessageHash(abi.encode(_message));
            targetSig = _signature;
        }

        address signer = digest.recover(targetSig);

        if (isAdmin(signer)) {
            return MAGICVALUE;
        }

        address caller = msg.sender;
        EnumerableSet.AddressSet storage approvedTargets = _accountPermissionsStorage().approvedTargets[signer];

        require(
            approvedTargets.contains(caller) || (approvedTargets.length() == 1 && approvedTargets.at(0) == address(0)),
            "Account: caller not approved target."
        );

        if (isActiveSigner(signer)) {
            magicValue = MAGICVALUE;
        }
    }

    /**
     * @notice Returns the hash of message that should be signed for EIP1271 verification.
     * @param message Message to be hashed i.e. `keccak256(abi.encode(data))`
     * @return Hashed message
     */
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        bytes32 messageHash = keccak256(abi.encode(MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), messageHash));
    }

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a transaction (called directly from an admin, or by entryPoint)
    function execute(address _target, uint256 _value, bytes calldata _calldata) external virtual onlyAdminOrEntrypoint {
        _registerOnFactory();
        _call(_target, _value, _calldata);
    }

    /// @notice Executes a sequence transaction (called directly from an admin, or by entryPoint)
    function executeBatch(
        address[] calldata _target,
        uint256[] calldata _value,
        bytes[] calldata _calldata
    ) external virtual onlyAdminOrEntrypoint {
        _registerOnFactory();

        require(_target.length == _calldata.length && _target.length == _value.length, "Account: wrong array lengths.");
        for (uint256 i = 0; i < _target.length; i++) {
            _call(_target[i], _value[i], _calldata[i]);
        }
    }

    /// @notice Deposit funds for this account in Entrypoint.
    function addDeposit() public payable {
        entryPoint().depositTo{ value: msg.value }(address(this));
    }

    /// @notice Withdraw funds for this account from Entrypoint.
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public {
        _onlyAdmin();
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers the account on the factory if it hasn't been registered yet.
    function _registerOnFactory() internal virtual {
        BaseAccountFactory factoryContract = BaseAccountFactory(factory);
        if (!factoryContract.isRegistered(address(this))) {
            factoryContract.onRegister(AccountCoreStorage.data().creationSalt);
        }
    }

    /// @dev Calls a target contract and reverts if it fails.
    function _call(
        address _target,
        uint256 value,
        bytes memory _calldata
    ) internal virtual returns (bytes memory result) {
        bool success;
        (success, result) = _target.call{ value: value }(_calldata);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view virtual override returns (bool) {
        return isAdmin(msg.sender) || msg.sender == address(this);
    }
}
