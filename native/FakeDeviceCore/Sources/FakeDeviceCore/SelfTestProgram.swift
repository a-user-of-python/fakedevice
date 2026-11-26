// SelfTestProgram.swift — FakeDeviceCore
//
// The built-in self-test program (the same bytes the web page embeds
// as TEST_B64 and test_emu.mjs loads as test.bin — verified identical).
// It prints "test" then "55" on the UART and halts.

public let selfTestProgram: [UInt8] = [0, 164, 166, 210, 64, 0, 192, 242, 161, 2, 0, 16, 34, 20, 64, 56, 98, 0, 0, 52, 2, 32, 0, 185, 253, 255, 255, 23, 3, 0, 128, 210, 36, 0, 128, 210, 99, 0, 4, 139, 132, 4, 0, 145, 159, 44, 0, 241, 171, 255, 255, 84, 69, 1, 128, 210, 102, 8, 197, 154, 199, 140, 5, 155, 198, 192, 0, 17, 6, 32, 0, 185, 231, 192, 0, 17, 7, 32, 0, 185, 66, 1, 128, 82, 2, 32, 0, 185, 0, 0, 64, 212, 116, 101, 115, 116, 10, 0]
