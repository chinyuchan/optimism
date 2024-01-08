// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Test } from "forge-std/Test.sol";

import { PreimageOracle, LibKeccak } from "src/cannon/PreimageOracle.sol";
import { PreimageKeyLib } from "src/cannon/PreimageKeyLib.sol";
import "src/cannon/libraries/CannonErrors.sol";

contract PreimageOracle_Test is Test {
    PreimageOracle oracle;

    /// @notice Sets up the testing suite.
    function setUp() public {
        oracle = new PreimageOracle();
        vm.label(address(oracle), "PreimageOracle");
    }

    /// @notice Test the pre-image key computation with a known pre-image.
    function test_keccak256PreimageKey_succeeds() public {
        bytes memory preimage = hex"deadbeef";
        bytes32 key = PreimageKeyLib.keccak256PreimageKey(preimage);
        bytes32 known = 0x02fd4e189132273036449fc9e11198c739161b4c0116a9a2dccdfa1c492006f1;
        assertEq(key, known);
    }

    /// @notice Tests that context-specific data [0, 24] bytes in length can be loaded correctly.
    function test_loadLocalData_onePart_succeeds() public {
        uint256 ident = 1;
        bytes32 word = bytes32(uint256(0xdeadbeef) << 224);
        uint8 size = 4;
        uint8 partOffset = 0;

        // Load the local data into the preimage oracle under the test contract's context.
        bytes32 contextKey = oracle.loadLocalData(ident, 0, word, size, partOffset);

        // Validate that the pre-image part is set
        bool ok = oracle.preimagePartOk(contextKey, partOffset);
        assertTrue(ok);

        // Validate the local data part
        bytes32 expectedPart = 0x0000000000000004deadbeef0000000000000000000000000000000000000000;
        assertEq(oracle.preimageParts(contextKey, partOffset), expectedPart);

        // Validate the local data length
        uint256 length = oracle.preimageLengths(contextKey);
        assertEq(length, size);
    }

    /// @notice Tests that multiple local key contexts can be used by the same address for the
    ///         same local data identifier.
    function test_loadLocalData_multipleContexts_succeeds() public {
        uint256 ident = 1;
        uint8 size = 4;
        uint8 partOffset = 0;

        // Form the words we'll be storing
        bytes32[2] memory words = [bytes32(uint256(0xdeadbeef) << 224), bytes32(uint256(0xbeefbabe) << 224)];

        for (uint256 i; i < words.length; i++) {
            // Load the local data into the preimage oracle under the test contract's context
            // and the given local context.
            bytes32 contextKey = oracle.loadLocalData(ident, bytes32(i), words[i], size, partOffset);

            // Validate that the pre-image part is set
            bool ok = oracle.preimagePartOk(contextKey, partOffset);
            assertTrue(ok);

            // Validate the local data part
            bytes32 expectedPart = bytes32(uint256(words[i] >> 64) | uint256(size) << 192);
            assertEq(oracle.preimageParts(contextKey, partOffset), expectedPart);

            // Validate the local data length
            uint256 length = oracle.preimageLengths(contextKey);
            assertEq(length, size);
        }
    }

    /// @notice Tests that context-specific data [0, 32] bytes in length can be loaded correctly.
    function testFuzz_loadLocalData_varyingLength_succeeds(
        uint256 ident,
        bytes32 localContext,
        bytes32 word,
        uint256 size,
        uint256 partOffset
    )
        public
    {
        // Bound the size to [0, 32]
        size = bound(size, 0, 32);
        // Bound the part offset to [0, size + 8]
        partOffset = bound(partOffset, 0, size + 8);

        // Load the local data into the preimage oracle under the test contract's context.
        bytes32 contextKey = oracle.loadLocalData(ident, localContext, word, uint8(size), uint8(partOffset));

        // Validate that the first local data part is set
        bool ok = oracle.preimagePartOk(contextKey, partOffset);
        assertTrue(ok);
        // Validate the first local data part
        bytes32 expectedPart;
        assembly {
            mstore(0x20, 0x00)

            mstore(0x00, shl(192, size))
            mstore(0x08, word)

            expectedPart := mload(partOffset)
        }
        assertEq(oracle.preimageParts(contextKey, partOffset), expectedPart);

        // Validate the local data length
        uint256 length = oracle.preimageLengths(contextKey);
        assertEq(length, size);
    }

    /// @notice Tests that a pre-image is correctly set.
    function test_loadKeccak256PreimagePart_succeeds() public {
        // Set the pre-image
        bytes memory preimage = hex"deadbeef";
        bytes32 key = PreimageKeyLib.keccak256PreimageKey(preimage);
        uint256 offset = 0;
        oracle.loadKeccak256PreimagePart(offset, preimage);

        // Validate the pre-image part
        bytes32 part = oracle.preimageParts(key, offset);
        bytes32 expectedPart = 0x0000000000000004deadbeef0000000000000000000000000000000000000000;
        assertEq(part, expectedPart);

        // Validate the pre-image length
        uint256 length = oracle.preimageLengths(key);
        assertEq(length, preimage.length);

        // Validate that the pre-image part is set
        bool ok = oracle.preimagePartOk(key, offset);
        assertTrue(ok);
    }

    /// @notice Tests that a pre-image cannot be set with an out-of-bounds offset.
    function test_loadLocalData_outOfBoundsOffset_reverts() public {
        bytes32 preimage = bytes32(uint256(0xdeadbeef));
        uint256 offset = preimage.length + 9;

        vm.expectRevert(PartOffsetOOB.selector);
        oracle.loadLocalData(1, 0, preimage, 32, offset);
    }

    /// @notice Tests that a pre-image cannot be set with an out-of-bounds offset.
    function test_loadKeccak256PreimagePart_outOfBoundsOffset_reverts() public {
        bytes memory preimage = hex"deadbeef";
        uint256 offset = preimage.length + 9;

        vm.expectRevert(PartOffsetOOB.selector);
        oracle.loadKeccak256PreimagePart(offset, preimage);
    }

    /// @notice Reading a pre-image part that has not been set should revert.
    function testFuzz_readPreimage_missingPreimage_reverts(bytes32 key, uint256 offset) public {
        vm.expectRevert("pre-image must exist");
        oracle.readPreimage(key, offset);
    }
}

contract PreimageOracle_LargePreimage_Test is Test {
    PreimageOracle oracle;

    /// @notice Sets up the testing suite.
    function setUp() public {
        oracle = new PreimageOracle();
        vm.label(address(oracle), "PreimageOracle");
    }

    /// @notice Tests that the PreimageOracle can absorb a large preimage and persist it correctly when the offset is
    ///         zero.
    function test_staticAddLargePreimage_zeroOffset_succeeds() public {
        bytes memory data = new bytes(200);
        for (uint256 i; i < data.length; i++) {
            data[i] = 0xFF;
        }

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 0, uint64(data.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(data);
        bytes32 expectedPart = bytes32(uint256(data.length << 192) | 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);

        assertTrue(oracle.preimagePartOk(key, 0));
        assertEq(oracle.preimageLengths(key), data.length);
        assertEq(oracle.preimageParts(key, 0), expectedPart);
    }


    /// @notice Tests that the PreimageOracle can absorb a large preimage in multiple segments and persist it correctly
    ///         when the offset is variable.
    function testFuzz_addLargePreimage_multipleSegments_succeeds(uint256 _partOffset) public {
        bytes memory data = new bytes(136);
        for (uint256 i; i < data.length; i++) {
            data[i] = 0xFF;
        }
        bytes memory fullData = bytes.concat(data, data, data);

        // Ensure that the part offset we'd like to store will enable us to store the full part, based on the segments
        // we're passing in below. If not, an attempt to store a partial part will happen, and the test will fail.
        // Partial parts are *only* allowed at the tail end of the preimage, so we allow for part offsets that
        // will surpass the end of the full preimage in the final segment, but not the others.
        _partOffset = bound(_partOffset, 0, fullData.length + 8 - 1);
        bool partIncludesSize = _partOffset < 8;
        bool partInFirstTwoSegments = _partOffset < data.length * 2 + 8;
        if (
            !partIncludesSize && partInFirstTwoSegments
                && ((_partOffset - 8) % LibKeccak.BLOCK_SIZE_BYTES) + 32 >= LibKeccak.BLOCK_SIZE_BYTES
        ) {
            _partOffset -= 32;
        }

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, uint128(_partOffset), uint64(fullData.length));

        // Absorb the preimage in 3 separate segments.
        oracle.absorbLargePreimagePart({ _contextKey: 0, _data: data, _finalize: false });
        oracle.absorbLargePreimagePart({ _contextKey: 0, _data: data, _finalize: false });
        oracle.absorbLargePreimagePart({ _contextKey: 0, _data: data, _finalize: true });

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(fullData);
        bytes32 expectedPart;
        if (_partOffset < 8) {
            assembly {
                mstore(0x00, shl(192, mload(fullData)))
                mstore(0x08, mload(add(fullData, 0x20)))
                expectedPart := mload(_partOffset)
            }
        } else {
            assembly {
                expectedPart := mload(add(add(fullData, 0x20), sub(_partOffset, 8)))
            }
        }
        assertTrue(oracle.preimagePartOk(key, _partOffset));
        assertEq(oracle.preimageLengths(key), fullData.length);
        assertEq(oracle.preimageParts(key, _partOffset), expectedPart);
    }

    /// @notice Tests that the PreimageOracle can absorb a large preimage and persist it correctly when the offset of
    ///         the part is in the middle of a block.
    function test_staticAddLargePreimage_middleOffset_succeeds() public {
        bytes memory data = new bytes(200);
        for (uint256 i; i < data.length; i++) {
            if (i >= 116) {
                data[i] = 0xDD;
            } else {
                data[i] = 0xFF;
            }
        }

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 100, uint64(data.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(data);
        bytes32 expectedPart = bytes32(type(uint256).max << 64 | 0xDDDDDDDDDDDDDDDD);

        assertTrue(oracle.preimagePartOk(key, 100));
        assertEq(oracle.preimageLengths(key), data.length);
        assertEq(oracle.preimageParts(key, 100), expectedPart);
    }

    /// @notice Tests that the PreimageOracle properly stores the preimage part if the offset is the last byte of a
    ///         block.
    function test_staticAddLargePreimage_blockBoundaryLast_succeeds() public {
        bytes memory data = new bytes(136);
        for (uint256 i; i < data.length; i++) {
            if (i >= 135) {
                data[i] = 0xFF;
            }
        }

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 143, uint64(data.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(data);
        bytes32 expectedPart = bytes32(uint256(0xFF << 248));

        assertTrue(oracle.preimagePartOk(key, 143));
        assertEq(oracle.preimageLengths(key), data.length);
        assertEq(oracle.preimageParts(key, 143), expectedPart);
    }

    /// @notice Tests that the PreimageOracle properly stores the preimage part if the offset is the first byte of a
    ///         block.
    function test_staticAddLargePreimage_blockBoundaryFirst_succeeds() public {
        bytes memory data = new bytes(137);
        for (uint256 i; i < data.length; i++) {
            if (i >= 136) {
                data[i] = 0xFF;
            }
        }

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 144, uint64(data.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(data);
        bytes32 expectedPart = bytes32(uint256(0xFF << 248));

        assertTrue(oracle.preimagePartOk(key, 144));
        assertEq(oracle.preimageLengths(key), data.length);
        assertEq(oracle.preimageParts(key, 144), expectedPart);
    }

    /// @notice Tests that the PreimageOracle properly stores the a preimage part in a given preimage.
    function testFuzz_addLargePreimage_succeeds(bytes calldata _preimage, uint256 _partOffset) public {
        _partOffset = bound(_partOffset, 0, _preimage.length + 8 - 1);

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, uint128(_partOffset), uint64(_preimage.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, _preimage, true);

        // Squeeze the sponge.
        oracle.squeezeLargePreimagePart(0);

        bytes32 key = PreimageKeyLib.keccak256PreimageKey(_preimage);

        bytes32 expectedPart;
        if (_partOffset < 8) {
            assembly {
                mstore(0x00, shl(192, _preimage.length))
                mstore(0x08, calldataload(_preimage.offset))
                expectedPart := mload(_partOffset)
            }
        } else {
            assembly {
                expectedPart := calldataload(add(_preimage.offset, sub(_partOffset, 8)))
            }
        }

        assertTrue(oracle.preimagePartOk(key, _partOffset));
        assertEq(oracle.preimageLengths(key), _preimage.length);
        assertEq(oracle.preimageParts(key, _partOffset), expectedPart);
    }

    /// @notice Tests that the `absorbLargePreimagePart` function reverts when absorbing a segment that contains the
    ///         part offset, but there is not enough data in the segment to store the full part. Note that this revert
    ///         should only happen when `finalize` is false, since partial parts are allowed at the tail end of the
    ///         preimage.
    function testFuzz_absorbLargePreimagePart_partialPart_reverts(uint256 _partOffset) public {
        bytes memory data = new bytes(136);
        for (uint256 i; i < data.length; i++) {
            data[i] = 0xFF;
        }
        bytes memory fullData = bytes.concat(data, data, data);

        _partOffset = bound(_partOffset, (data.length - 32) + 8, data.length + 8 - 1);

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, uint128(_partOffset), uint64(fullData.length));

        // Absorb the preimage in 3 separate segments.
        vm.expectRevert(PartOffsetOOB.selector);
        oracle.absorbLargePreimagePart(0, data, false);
    }

    /// @notice Tests that the preimage oracle's `absorbLargePreimagePart` reverts when the input length is not a
    ///         multiple of the block size and it is not the final segment being absorbed.
    function test_absorbLargePreimagePart_invalidInputLength_reverts() public {
        // Absorb the preimage.
        vm.expectRevert(InvalidInputLength.selector);
        oracle.absorbLargePreimagePart(0, hex"deadbeef", false);
    }

    /// @notice Tests that the preimage oracle's `squeezeLargePreimagePart` function reverts when the offset is
    ///         out of bounds of the preimage size + 8.
    function test_squeezeLargePreimagePart_oobPartOffset_reverts() public {
        bytes memory data = new bytes(200);

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 500, uint64(data.length));

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        vm.expectRevert(PartOffsetOOB.selector);
        oracle.squeezeLargePreimagePart(0);
    }

    /// @notice Tests that the preimage oracle's `squeezeLargePreimagePart` reverts when the final preimage size is not
    /// equal to the claimed size.
    function test_squeezeLargePreimagePart_invalidInputLength_reverts() public {
        bytes memory data = new bytes(200);

        // Init absorbtion process.
        oracle.initLargeKeccak256Preimage(0, 0, 201);

        // Absorb the preimage.
        oracle.absorbLargePreimagePart(0, data, true);

        // Squeeze the sponge.
        vm.expectRevert(InvalidClaimedSize.selector);
        oracle.squeezeLargePreimagePart(0);
    }
}
