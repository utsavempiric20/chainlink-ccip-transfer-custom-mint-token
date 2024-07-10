// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

interface IMintToken {
    function mintToken(address to, uint256 amount) external;

    function burnToken(address from, uint256 amount) external;

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
}

contract TransferTokenCrossChain is OwnerIsCreator {
    using SafeERC20 for IERC20;

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error NothingToWithdraw();
    error FailedToWithdrawEth(address owner, address target, uint256 value);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiverAddress();

    event TokensTransferred(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        address token,
        uint256 tokenAmount,
        address feeToken,
        uint256 fees
    );

    mapping(uint64 => bool) public allowlistedChains;
    IMintToken iMintToken;
    IRouterClient private s_router;
    IERC20 private s_linkToken;

    uint64 destinationChainSelector;
    address receiverAddress;
    address tokenAddress;
    address lastSenderAddress;

    constructor(
        address _iMintToken,
        address _router,
        address _link,
        uint64 _destinationChainSelector,
        address _receiverAddress,
        address _tokenAddress
    ) {
        iMintToken = IMintToken(_iMintToken);
        s_router = IRouterClient(_router);
        s_linkToken = IERC20(_link);
        destinationChainSelector = _destinationChainSelector;
        receiverAddress = _receiverAddress;
        tokenAddress = _tokenAddress;
    }

    modifier onlyAllowlistedChain(uint64 _destinationChainSelector) {
        if (!allowlistedChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    function mintToken(uint256 amount) public {
        iMintToken.mintToken(msg.sender, amount);
        transferTokensPayNative(
            destinationChainSelector,
            receiverAddress,
            tokenAddress,
            amount,
            msg.sender
        );
        iMintToken.transferFrom(receiverAddress, lastSenderAddress, amount);
        IMintToken(receiverAddress).mintToken(lastSenderAddress, amount);
    }

    function burn(uint256 amount) public {
        iMintToken.burnToken(msg.sender, amount);
        transferTokensPayNative(
            destinationChainSelector,
            receiverAddress,
            tokenAddress,
            amount,
            msg.sender
        );
        iMintToken.transferFrom(receiverAddress, lastSenderAddress, amount);
        IMintToken(receiverAddress).burnToken(lastSenderAddress, amount);
    }

    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedChains[_destinationChainSelector] = allowed;
    }

    function transferTokensPayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount,
        address _senderAddress
    )
        internal
        onlyOwner
        onlyAllowlistedChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _token,
            _amount,
            address(0),
            _senderAddress
        );

        lastSenderAddress = abi.decode(evm2AnyMessage.data, (address));
        console.log("lastSenderAddress : ", lastSenderAddress);

        uint256 fees = s_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        IERC20(_token).approve(address(s_router), _amount);

        messageId = s_router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            _token,
            _amount,
            address(0),
            fees
        );

        return messageId;
    }

    function _buildCCIPMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress,
        address _senderAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });

        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: abi.encode(_senderAddress),
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 0})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }
}
