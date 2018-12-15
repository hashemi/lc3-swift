import Darwin


// Ports the FD_ZERO and FD_SET C macros in Darwin to Swift.
// https://github.com/apple/darwin-xnu/blob/master/bsd/sys/_types/_fd_def.h
// This is not portable to Linux.
extension fd_set {
    // FD_ZERO(self)
    mutating func fdZero() {
        bzero(&fds_bits, MemoryLayout.size(ofValue: fds_bits))
    }
    
    // FD_SET(fd, self)
    mutating func fdSet(fd: Int32) {
        let __DARWIN_NFDBITS = Int32(MemoryLayout<Int32>.size) * __DARWIN_NBBY
        let bits = UnsafeMutableBufferPointer(start: &fds_bits.0, count: 32)
        bits[Int(CUnsignedLong(fd) / CUnsignedLong(__DARWIN_NFDBITS))] |= __int32_t(
            CUnsignedLong(1) << CUnsignedLong(fd % __DARWIN_NFDBITS)
        )
    }
}

struct Memory {
    private let storage = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: Int(UInt16.max))
    
    private static let KBSR: UInt16 = 0xFE00 // keyboard status
    private static let KBDR: UInt16 = 0xFE02 // keyboard data
    
    subscript(_ idx: UInt16) -> UInt16 {
        get {
            func check_key() -> Bool {
                var readfds = fd_set()
                readfds.fdZero()
                readfds.fdSet(fd: STDIN_FILENO)
                
                var timeout = timeval(tv_sec: 0, tv_usec: 0)
                return select(1, &readfds, nil, nil, &timeout) != 0
            }
            
            if idx == Memory.KBSR {
                if check_key() {
                    storage[Int(Memory.KBSR)] = (1 << 15)
                    storage[Int(Memory.KBDR)] = UInt16(getchar())
                } else {
                    storage[Int(Memory.KBSR)] = 0
                }
            }

            return storage[Int(idx)]
        }
        
        set { storage[Int(idx)] = newValue }
    }
    
    func pointerAt(offset: UInt16) -> UnsafeMutablePointer<UInt16> {
        let rebased = UnsafeMutableBufferPointer(rebasing: storage[Int(offset)...])
        return rebased.baseAddress!
    }
}

struct RegisterSet {
    enum Register: UInt16, CaseIterable {
        case r0, r1, r2, r3, r4, r5, r6, r7,
        pc, cond
    }
    
    let storage = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: Register.allCases.count)
    
    subscript(r: Register) -> UInt16 {
        get {
            return storage[Int(r.rawValue)]
        }
        
        set {
            storage[Int(r.rawValue)] = newValue
        }
    }
    
    static let pos: UInt16 = (1 << 0)
    static let zro: UInt16 = (1 << 1)
    static let neg: UInt16 = (1 << 2)
    
    subscript(_ rn: UInt16) -> UInt16 {
        get {
            return storage[Int(rn)]
        }
        
        set {
            storage[Int(rn)] = newValue
            
            // update flags
            if newValue == 0 {
                self[.cond] = RegisterSet.zro
            } else if (newValue >> 15) == 1 {
                self[.cond] = RegisterSet.neg
            } else {
                self[.cond] = RegisterSet.pos
            }
        }
    }
}

enum OpCode: UInt16 {
    case br, add, ld, st, jsr, and, ldr, str, rti, not,
         ldi, sti, jmp, res, lea, trap
}

enum TrapCode: UInt16 {
    case getc  = 0x20 // get character from keyboard
    case out   = 0x21 // output a character
    case puts  = 0x22 // output a word string
    case `in`  = 0x23 // input a string
    case putsp = 0x24 // output a byte string
    case halt  = 0x25 // halt the program
}

struct Instruction {
    let code: UInt16
    init(_ code: UInt16) {
        self.code = code
    }
    
    private static func sign_extend(_ x: UInt16, bit_count: UInt16) -> UInt16 {
        if ((x >> (bit_count - 1)) & UInt16(1)) != 0 {
            return x | (0xFFFF << bit_count)
        } else {
            return x
        }
    }
    
    var op: OpCode? { return OpCode(rawValue: code >> 12) }
    
    var trapCode: TrapCode? { return TrapCode(rawValue: code & 0xFF) }
    
    var r0: UInt16 { return (code >> 9) & 0x7 }
    var r1: UInt16 { return (code >> 6) & 0x7 }
    var imm_flag: Bool { return ((code >> 5) & 0x1) == 1 }
    var imm5: UInt16 { return Instruction.sign_extend(code & 0x1F, bit_count: 5) }
    var r2: UInt16 { return code & 0x7 }
    var pc_offset: UInt16 { return Instruction.sign_extend(code & 0x1ff, bit_count: 9) }
    var long_pc_offset: UInt16 { return Instruction.sign_extend(code & 0x7ff, bit_count: 11) }
    var long_flag: Bool { return ((code >> 11) & 1) != 0 }
    var offset: UInt16 { return Instruction.sign_extend(code & 0x3F, bit_count: 6) }
}

let PC_START: UInt16 = 0x3000

struct VM {
    var memory: Memory
    var reg: RegisterSet
    
    init() {
        self.memory = Memory()
        self.reg = RegisterSet()
        reg[.pc] = PC_START
    }
    
    mutating func run() {
        var running = true

        func handleTrap(_ instr: Instruction) {
            let trapCode = instr.trapCode!
            
            switch trapCode {
            case .getc:
                reg[.r0] = UInt16(getchar())
                
            case .out:
                putc(Int32(reg[.r0]), stdout)
                fflush(stdout)
                
            case .puts:
                var idx = reg[.r0]
                while memory[idx] != 0 {
                    putc(Int32(memory[idx]), stdout)
                    idx += 1
                }
                fflush(stdout)
                
            case .in:
                print("Enter a character: ", terminator: "")
                reg[.r0] = UInt16(getchar())
                
            case .putsp:
                var idx = reg[.r0]
                while memory[idx] != 0 {
                    let char1 = Int32(memory[idx] & 0xFF)
                    putc(char1, stdout)
                    let char2 = Int32(memory[idx] >> 8)
                    if char2 != 0 { putc(char2, stdout) }
                    idx += 1
                }
                fflush(stdout)
                
            case .halt:
                puts("HALT")
                fflush(stdout)
                running = false
            }
        }
        
        while running {
            /* FETCH */
            let instr = Instruction(memory[reg[.pc]])
            reg[.pc] += 1
            guard let op = instr.op else {
                fatalError("bad opcode")
            }
            
            switch op {
            case .add:
                reg[instr.r0] = reg[instr.r1] &+ (instr.imm_flag ? instr.imm5 : reg[instr.r2])
                
            case .and:
                reg[instr.r0] = reg[instr.r1] & (instr.imm_flag ? instr.imm5 : reg[instr.r2])
                
            case .not:
                reg[instr.r0] = ~reg[instr.r1]
            
            case .br:
                let cond_flag = instr.r0
                if (cond_flag & reg[.cond]) != 0 {
                    reg[.pc] &+= instr.pc_offset
                }
            
            case .jmp:
                reg[.pc] = reg[instr.r1]
                
            case .jsr:
                reg[.r7] = reg[.pc]
                if instr.long_flag {
                    reg[.pc] &+= instr.long_pc_offset // JSR
                } else {
                    reg[.pc] = reg[instr.r1] // JSRR
                }
            
            case .ld:
                reg[instr.r0] = memory[reg[.pc] &+ instr.pc_offset]
            
            case .ldr:
                reg[instr.r0] = memory[reg[instr.r1] &+ instr.offset]
            
            case .lea:
                reg[instr.r0] = reg[.pc] &+ instr.pc_offset
            
            case .st:
                memory[reg[.pc] &+ instr.pc_offset] = reg[instr.r0]
            
            case .sti:
                memory[memory[reg[.pc] &+ instr.pc_offset]] = reg[instr.r0]
            
            case .str:
                memory[reg[instr.r1] &+ instr.offset] = reg[instr.r0]
            
            case .trap:
                handleTrap(instr)

            case .ldi:
                reg[instr.r0] = memory[memory[reg[.pc] &+ instr.pc_offset]]
                
            case .rti: fallthrough
            case .res:
                fatalError("bad opcode")
            }
        }
    }

    mutating func read_image_file(_ file: UnsafeMutablePointer<FILE>) {
        func swap16(_ x: UInt16) -> UInt16 {
            return (x << 8) | (x >> 8)
        }
        
        var origin: UInt16 = 0
        fread(&origin, MemoryLayout.size(ofValue: origin), 1, file)
        origin = swap16(origin)
        
        let max_read = UInt16.max - origin
        let read = fread(memory.pointerAt(offset: origin), MemoryLayout.size(ofValue: origin), Int(max_read), file)
        
        for idx in origin..<origin + UInt16(read) {
            memory[idx] = swap16(memory[idx])
        }
    }

    mutating func read_image(_ image_path: String) -> Bool {
        guard let file = fopen(image_path, "rb") else { return false }
        read_image_file(file)
        fclose(file)
        return true
    }
}

// main
var vm = VM()

if CommandLine.argc < 2 {
    print("\(CommandLine.arguments[0]) [image-file1] ...")
    exit(2)
}

for arg in CommandLine.arguments[1...] {
    guard vm.read_image(arg) else {
        fatalError("failed to load image: \(arg)")
    }
}

var original_tio = termios()

func disable_input_buffering() {
    tcgetattr(STDIN_FILENO, &original_tio)
    var new_tio = original_tio
    new_tio.c_lflag = UInt(Int32(new_tio.c_lflag) & ~ICANON & ~ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &new_tio)
}

func restore_input_buffering() {
    tcsetattr(STDIN_FILENO, TCSANOW, &original_tio)
}

func handle_interrupt(_ signal: Int32) {
    restore_input_buffering()
    print("")
    exit(-2)
}

signal(SIGINT, handle_interrupt)
disable_input_buffering()

vm.run()

restore_input_buffering()
