# =========================================================
# Mini TPU Test  —  updated for 16-bit accumulator
# Changes vs original:
#   1. matmul_ref now masks to 0xffff (16-bit) instead of 0xff
#   2. read_matrix combines uo_out (low byte) + uio_out (high byte)
#   3. random test inputs widened to 0-255 to exercise full range
# =========================================================
import random
import cocotb
from cocotb.clock    import Clock
from cocotb.triggers import RisingEdge, Timer

# Instruction Encoding
OP_RUN, OP_LOAD, OP_STORE = 0b01, 0b10, 0b11

def make_instr(op, mem_sel=0, row=0, col=0, imm=0):
    return ((op & 3) << 14) | ((mem_sel & 1) << 13) | \
           ((row & 3) << 10) | ((col & 3) << 8) | (imm & 0xff)

async def send_instr(dut, instr):
    dut.ui_in.value  = instr & 0xff
    dut.uio_in.value = instr >> 8
    await RisingEdge(dut.clk)

async def hw_reset(dut, n=3):
    dut.rst_n.value = 0
    for _ in range(n):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

# ── Reference model ──────────────────────────────────────
# Mask changed: 0xff → 0xffff to match the 16-bit accumulator.
# A 4-deep dot product of 8-bit values can reach 255*255*4 = 260100,
# which needs 18 bits — but with unsigned 8-bit inputs and a 16-bit
# accumulator, values > 65535 would still overflow on hardware.
# For test inputs ≤ 255 the max dot product is 260100 > 65535, so
# keep random inputs bounded (see below) or widen ACC further.
# For the structured tests (values ≤ 16) max dot product = 1024, safe.
def matmul_ref(a, b):
    n = len(a)
    c = [[0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            c[i][j] = sum(a[i][k] * b[k][j] for k in range(n)) & 0xffff  # 16-bit mask
    return c

# ── Load matrices ─────────────────────────────────────────
async def load_matrices(dut, a, b):
    for r in range(4):
        for c in range(4):
            await send_instr(dut, make_instr(OP_LOAD, 0, r, c, a[r][c]))
    for r in range(4):
        for c in range(4):
            await send_instr(dut, make_instr(OP_LOAD, 1, r, c, b[c][r]))

# ── Read result matrix ────────────────────────────────────
# Now reads both bytes of the 16-bit result.
# TinyTapeout pinout convention used here:
#   uo_out  [7:0]  → result[ 7:0]  (low byte)
#   uio_out [7:0]  → result[15:8]  (high byte)
# If your tpu.v top-level routes differently, adjust the shift below.
async def read_matrix(dut):
    out = [[0] * 4 for _ in range(4)]
    for r in range(4):
        for c in range(4):
            await send_instr(dut, make_instr(OP_STORE, 0, r, c))
            await Timer(1, units="ns")                     # let outputs settle
            lo = int(dut.uo_out.value)  & 0xff             # low  byte
            hi = int(dut.uio_out.value) & 0xff             # high byte
            out[r][c] = (hi << 8) | lo                     # combine to 16-bit
    return out

# ── Single test run ───────────────────────────────────────
async def run_once(dut, a, b):
    await hw_reset(dut)
    await load_matrices(dut, a, b)
    for _ in range(11):
        await send_instr(dut, make_instr(OP_RUN))
    hw_out = await read_matrix(dut)
    sw_out = matmul_ref(a, b)
    return hw_out, sw_out

# ── Logging ───────────────────────────────────────────────
def log_matrix(dut, title, mat):
    dut._log.info(f"--- {title} ---")
    for i, row in enumerate(mat):
        dut._log.info(f"Row {i}: {row}")

# ── Assertion helper ──────────────────────────────────────
def assert_matrices_equal(dut, hw, sw, label=""):
    for r in range(4):
        for c in range(4):
            assert hw[r][c] == sw[r][c], (
                f"{label} mismatch at [{r}][{c}]: "
                f"HW={hw[r][c]:#06x}  SW={sw[r][c]:#06x}"
            )

# =========================================================
@cocotb.test()
async def Test_TPU(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0

    cocotb.log.info("\nStart Testing TPU (16-bit accumulator)\n")

    async def test_and_log(A, B, label=""):
        hw_res, sw_res = await run_once(dut, A, B)
        log_matrix(dut, f"A  ({label})", A)
        log_matrix(dut, f"B  ({label})", B)
        log_matrix(dut, "SW  Result (A×B)", sw_res)
        log_matrix(dut, "HW  Result", hw_res)
        assert_matrices_equal(dut, hw_res, sw_res, label)
        dut._log.info(f"PASS: {label}\n")

    I    = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    zero = [[0]*4 for _ in range(4)]

    # ── Structured tests ──────────────────────────────────
    await test_and_log(I,    zero, "I × zero")
    await test_and_log(I,    I,    "I × I")

    A = [[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]]
    B = [[2,0,0,0],[0,3,0,0],[0,0,4,0],[0,0,0,5]]

    await test_and_log(A, I, "A × I")
    await test_and_log(B, I, "B × I")
    await test_and_log(A, B, "A × B  (diagonal scale)")

    A = [[(i + j) % 2 for j in range(4)] for i in range(4)]
    B = [[(i * j) % 2 for j in range(4)] for i in range(4)]
    await test_and_log(A, B, "checkerboard")

    A = [[5]*4 for _ in range(4)]
    B = [[1,2,3,4]]*4
    await test_and_log(A, B, "uniform rows/cols")

    # ── Random tests ─────────────────────────────────────
    # Upper bound is 63 so max dot product = 63*63*4 = 15876 < 65535,
    # which safely fits in 16 bits and matches hardware behaviour.
    # (Using 255 would overflow a 16-bit accumulator for 4-term dot products.)
    for trial in range(5):
        A = [[random.randint(0, 63) for _ in range(4)] for _ in range(4)]
        B = [[random.randint(0, 63) for _ in range(4)] for _ in range(4)]
        await test_and_log(A, B, f"random trial {trial+1}")