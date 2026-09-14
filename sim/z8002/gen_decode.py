#!/usr/bin/env python3
"""Generate rtl/z8002_dec.svh from MAME's Z8000 opcode table.

MAME dispatches on the first opcode word through z8000tbl.hxx: a list of
(first, last, step) ranges, later entries overriding earlier ones, each naming a
handler and its cycle cost. This script replays that table exactly and emits a
SystemVerilog decode function mapping the first word to a control word:

    {cycles[9:0], cls[5:0], sz[1:0], aop[4:0], mode[3:0], var[3:0], next[1:0], priv, epu}

Every handler name is classified below. The classification is the only
hand-written part; an unclassified handler is a hard error, so a table change
cannot slip through silently. It also writes the DAB result table.

    gen_decode.py <mame_src_dir> <out.svh>
"""
import re, sys

src, out = sys.argv[1], sys.argv[2]
tbl = open(src + '/z8000tbl.hxx').read()
ENTRIES = []
for m in re.finditer(r'\{\s*(0x[0-9a-f]+),\s*(0x[0-9a-f]+),\s*(\d+),\s*(\d+),\s*(\d+),\s*&z8002_device::(\w+)', tbl):
    ENTRIES.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3)),
                    int(m.group(4)), int(m.group(5)), m.group(6)))

CLS = ['NOP', 'ALU', 'MUL', 'DIV', 'UN', 'BITDYN', 'STORE', 'EX', 'PUSH', 'POP',
       'LDA', 'JP', 'CALL', 'RET', 'CALR', 'JR', 'DJNZ', 'IRET', 'LDPS', 'HALT',
       'DIEI', 'LDCTL', 'MREQ', 'TRAPREQ', 'FLAGS', 'SHIFT', 'DAB', 'EXTS', 'TCC',
       'LDK', 'LDBS', 'RXDB', 'BLK', 'TR', 'LDM', 'IO', 'EPU']
AOP = ['ADD', 'ADC', 'SUB', 'SBC', 'OR', 'AND', 'XOR', 'CP', 'LD', 'COM', 'NEG',
       'TEST', 'TSET', 'CLR', 'LDIMM', 'CPIMM', 'INC', 'DEC', 'RES', 'SET', 'BIT']
MODE = ['NONE', 'IMM', 'IR', 'DA', 'X', 'R', 'REL', 'BA', 'BX']
SZ = {'B': 0, 'W': 1, 'L': 2, 'Q': 3}


def cw(cls, sz='W', aop='LD', mode='NONE', var=0, nxt=0, priv=0, epu=0):
    return dict(cls=cls, sz=sz, aop=aop, mode=mode, var=var, nxt=nxt, priv=priv, epu=epu)


def spec(h):
    hb = int(h[1:3], 16) if len(h) > 2 and re.match(r'Z[0-9A-F]{2}_', h) else None
    im = '_0000_' in h[3:9] or h[3:8] == '_0000'   # second nibble group zero form

    if h == 'zinvalid':
        return cw('NOP')
    # ---- two-operand register destination ------------------------------
    alu_lo = {0x0: ('ADD', 'B'), 0x1: ('ADD', 'W'), 0x2: ('SUB', 'B'), 0x3: ('SUB', 'W'),
              0x4: ('OR', 'B'), 0x5: ('OR', 'W'), 0x6: ('AND', 'B'), 0x7: ('AND', 'W'),
              0x8: ('XOR', 'B'), 0x9: ('XOR', 'W'), 0xA: ('CP', 'B'), 0xB: ('CP', 'W')}
    alu_l = {0x0: 'CP', 0x2: 'SUB', 0x4: 'LD', 0x6: 'ADD'}
    if hb is not None:
        grp, lo = hb >> 4, hb & 15
        if grp in (0x0, 0x4, 0x8) and lo in alu_lo:
            aop, sz = alu_lo[lo]
            if grp == 0x0:
                mode = 'IMM' if im else 'IR'
            elif grp == 0x4:
                mode = 'DA' if im else 'X'
            else:
                mode = 'R'
            nxt = {'IMM': 1, 'IR': 0, 'DA': 1, 'X': 1, 'R': 0}[mode]
            return cw('ALU', sz, aop, mode, nxt=nxt)
        if grp in (0x1, 0x5, 0x9) and lo in alu_l and not h.startswith(('Z11', 'Z13', 'Z15', 'Z17', 'Z51', 'Z53', 'Z55', 'Z57', 'Z91', 'Z93', 'Z95', 'Z97')):
            if grp == 0x1:
                mode = 'IMM' if im else 'IR'
            elif grp == 0x5:
                mode = 'DA' if im else 'X'
            else:
                mode = 'R'
            nxt = {'IMM': 2, 'IR': 0, 'DA': 1, 'X': 1, 'R': 0}[mode]
            return cw('ALU', 'L', alu_l[lo], mode, nxt=nxt)
        if grp in (0x1, 0x5, 0x9) and lo in (0x8, 0x9, 0xA, 0xB):
            cls = 'MUL' if lo in (0x8, 0x9) else 'DIV'
            if h == 'Z18_ssN0_dddd':
                # MAME reads RL(src) here, a register, despite the "@rs" name
                return cw('MUL', 'L', 'LD', 'R')
            sz = 'L' if lo in (0x8, 0xA) else 'W'
            if grp == 0x1:
                mode = 'IMM' if (im or '_00N0_' in h) else 'IR'
            elif grp == 0x5:
                mode = 'DA' if im else 'X'
            else:
                mode = 'R'
            nxt = {'IMM': 2 if sz == 'L' else 1, 'IR': 0, 'DA': 1, 'X': 1, 'R': 0}[mode]
            return cw(cls, sz, 'LD', mode, nxt=nxt)
        if hb in (0x20, 0x21, 0x60, 0x61, 0xA0, 0xA1):
            sz = 'B' if hb & 1 == 0 else 'W'
            mode = {0x2: 'IMM' if im else 'IR', 0x6: 'DA' if im else 'X', 0xA: 'R'}[hb >> 4]
            nxt = {'IMM': 1, 'IR': 0, 'DA': 1, 'X': 1, 'R': 0}[mode]
            return cw('ALU', sz, 'LD', mode, nxt=nxt)
        if hb in (0x30, 0x31, 0x35):
            sz = {0x30: 'B', 0x31: 'W', 0x35: 'L'}[hb]
            return cw('ALU', sz, 'LD', 'REL' if im else 'BA', nxt=1)
        if hb in (0x70, 0x71, 0x75):
            sz = {0x70: 'B', 0x71: 'W', 0x75: 'L'}[hb]
            return cw('ALU', sz, 'LD', 'BX', nxt=1)
        if hb in (0xB4, 0xB5, 0xB6, 0xB7):
            aop = 'ADC' if hb in (0xB4, 0xB5) else 'SBC'
            return cw('ALU', 'B' if hb & 1 == 0 else 'W', aop, 'R')
        if hb in (0x32, 0x33, 0x37):
            sz = {0x32: 'B', 0x33: 'W', 0x37: 'L'}[hb]
            return cw('STORE', sz, 'LD', 'REL' if im else 'BA', nxt=1)
        if hb in (0x72, 0x73, 0x77):
            sz = {0x72: 'B', 0x73: 'W', 0x77: 'L'}[hb]
            return cw('STORE', sz, 'LD', 'BX', nxt=1)
        if hb in (0x2E, 0x2F):
            return cw('STORE', 'B' if hb == 0x2E else 'W', 'LD', 'IR')
        if hb == 0x1D:
            return cw('STORE', 'L', 'LD', 'IR')
        if hb == 0x4E:
            return cw('STORE', 'B', 'LD', 'X', nxt=1)
        if hb == 0x5D:
            return cw('STORE', 'L', 'LD', 'DA' if im else 'X', nxt=1)
        if hb in (0x6E, 0x6F):
            return cw('STORE', 'B' if hb == 0x6E else 'W', 'LD', 'DA' if im else 'X', nxt=1)

    # ---- single operand (Z0C/Z0D @rd, Z4C/Z4D addr, Z8C/Z8D reg) ----------
    un_code = {'0000': 'COM', '0001': 'CPIMM', '0010': 'NEG', '0100': 'TEST',
               '0101': 'LDIMM', '0110': 'TSET', '1000': 'CLR'}
    m = re.match(r'Z(0C|0D|4C|4D|8C|8D)_(dddd|ddN0|0000)_(\d{4})', h)
    if m and m.group(3) in un_code and not (m.group(1) in ('8C',) and m.group(3) in ('0001',)):
        sz = 'B' if m.group(1)[1] == 'C' else 'W'
        aop = un_code[m.group(3)]
        grp = m.group(1)[0]
        if grp == '0':
            mode = 'IR'
            nxt = 1 if aop in ('CPIMM', 'LDIMM') else 0
        elif grp == '4':
            mode = 'DA' if m.group(2) == '0000' else 'X'
            nxt = 2 if aop in ('CPIMM', 'LDIMM') else 1
        else:
            mode, nxt = 'R', 0
        var = 0
        if h == 'Z0C_ddN0_0000':
            var |= 1        # MAME reads the address register from NIB3
        if h == 'Z4C_0000_0000_addr':
            var |= 2        # MAME reads a word and complements its low byte
        return cw('UN', sz, aop, mode, var, nxt)
    if h == 'Z0D_ddN0_1001_imm16':
        return cw('PUSH', 'W', 'LD', 'IMM', nxt=1)
    if h in ('Z1C_ddN0_1000', 'Z5C_0000_1000_addr', 'Z5C_ddN0_1000_addr', 'Z9C_dddd_1000'):
        mode = {'Z1C': 'IR', 'Z9C': 'R'}.get(h[:3], 'DA' if '0000_1000' in h else 'X')
        return cw('UN', 'L', 'TEST', mode, nxt=1 if h[:3] == 'Z5C' else 0)
    m = re.match(r'Z(2|6|A)([2-7])_(ddN0|0000|dddd)_imm4', h)
    if m:
        lo = int(m.group(2))
        aop = {2: 'RES', 3: 'RES', 4: 'SET', 5: 'SET', 6: 'BIT', 7: 'BIT'}[lo]
        sz = 'B' if lo % 2 == 0 else 'W'
        mode = {'2': 'IR', '6': 'DA' if m.group(3) == '0000' else 'X', 'A': 'R'}[m.group(1)]
        return cw('UN', sz, aop, mode, nxt=1 if m.group(1) == '6' else 0)
    m = re.match(r'Z2([2-7])_0000_ssss_0000_dddd', h)
    if m:
        lo = int(m.group(1))
        aop = {2: 'RES', 3: 'RES', 4: 'SET', 5: 'SET', 6: 'BIT', 7: 'BIT'}[lo]
        return cw('BITDYN', 'B' if lo % 2 == 0 else 'W', aop, 'R', nxt=1)
    m = re.match(r'Z(2|6|A)([8-9AB])_(ddN0|0000|dddd)_imm4m1', h)
    if m:
        lo = int(m.group(2), 16)
        aop = 'INC' if lo in (8, 9) else 'DEC'
        sz = 'B' if lo in (8, 0xA) else 'W'
        mode = {'2': 'IR', '6': 'DA' if m.group(3) == '0000' else 'X', 'A': 'R'}[m.group(1)]
        return cw('UN', sz, aop, mode, nxt=1 if m.group(1) == '6' else 0)
    # ---- exchange ------------------------------------------------------------
    if h in ('Z2C_ssN0_dddd', 'Z2D_ssN0_dddd'):
        return cw('EX', 'B' if h[2] == 'C' else 'W', 'LD', 'IR')
    if h[:3] in ('Z6C', 'Z6D'):
        return cw('EX', 'B' if h[2] == 'C' else 'W', 'LD', 'DA' if '_0000_' in h else 'X', nxt=1)
    if h in ('ZAC_ssss_dddd', 'ZAD_ssss_dddd'):
        return cw('EX', 'B' if h[2] == 'C' else 'W', 'LD', 'R')
    # ---- stack -----------------------------------------------------------------
    push = {'Z11_ddN0_ssN0': ('L', 'IR', 0), 'Z13_ddN0_ssN0': ('W', 'IR', 0),
            'Z51_ddN0_0000_addr': ('L', 'DA', 1), 'Z51_ddN0_ssN0_addr': ('L', 'X', 1),
            'Z53_ddN0_0000_addr': ('W', 'DA', 1), 'Z53_ddN0_ssN0_addr': ('W', 'X', 1),
            'Z91_ddN0_ssss': ('L', 'R', 0), 'Z93_ddN0_ssss': ('W', 'R', 0)}
    if h in push:
        sz, mode, nxt = push[h]
        return cw('PUSH', sz, 'LD', mode, nxt=nxt)
    pop = {'Z15_ssN0_ddN0': ('L', 'R', 0), 'Z17_ssN0_ddN0': ('W', 'IR', 0),
           'Z55_ssN0_0000_addr': ('L', 'DA', 1), 'Z55_ssN0_ddN0_addr': ('L', 'X', 1),
           'Z57_ssN0_0000_addr': ('W', 'DA', 1), 'Z57_ssN0_ddN0_addr': ('W', 'X', 1),
           'Z95_ssN0_dddd': ('L', 'R', 0), 'Z97_ssN0_dddd': ('W', 'R', 0)}
    if h in pop:
        sz, mode, nxt = pop[h]
        return cw('POP', sz, 'LD', mode, nxt=nxt)
    # ---- address loads, jumps ------------------------------------------------
    lda = {'Z34_0000_dddd_dsp16': 0, 'Z34_ssN0_dddd_imm16': 1,
           'Z74_ssN0_dddd_0000_xxxx_0000_0000': 2, 'Z76_0000_dddd_addr': 3, 'Z76_ssN0_dddd_addr': 4}
    if h in lda:
        return cw('LDA', 'W', 'LD', 'NONE', lda[h], nxt=1)
    if h == 'Z1E_ddN0_cccc':
        return cw('JP', mode='IR')
    if h[:3] == 'Z5E':
        return cw('JP', mode='DA' if '_0000_' in h else 'X', nxt=1)
    if h == 'Z1F_ddN0_0000':
        return cw('CALL', mode='IR')
    if h[:3] == 'Z5F':
        return cw('CALL', mode='DA' if h.startswith('Z5F_0000') else 'X', nxt=1)
    if h == 'Z9E_0000_cccc':
        return cw('RET')
    if h == 'ZD_dsp12':
        return cw('CALR')
    if h == 'ZE_cccc_dsp8':
        return cw('JR')
    if h == 'ZF_dddd_0dsp7':
        return cw('DJNZ', 'B')
    if h == 'ZF_dddd_1dsp7':
        return cw('DJNZ', 'W')
    # ---- block ---------------------------------------------------------------
    m = re.match(r'Z(1C|5C)_', h)
    if m and ('nmin1' in h):
        tomem = '_1001_' in h
        if h[:3] == 'Z1C':
            mode, nxt = 'IR', 1
        else:
            mode, nxt = ('DA' if h.startswith('Z5C_0000') else 'X'), 2
        return cw('LDM', 'W', 'LD', mode, 0 if tomem else 1, nxt)
    if h[:3] in ('ZBA', 'ZBB'):
        return cw('BLK', 'B' if h[2] == 'A' else 'W', nxt=1)
    if h[:3] == 'ZB8':
        return cw('TR', 'B', nxt=1)
    # ---- system ----------------------------------------------------------------
    if h == 'Z39_ssN0_0000':
        return cw('LDPS', mode='IR', priv=1)
    if h[:3] == 'Z79':
        return cw('LDPS', mode='DA' if h.startswith('Z79_0000') else 'X', nxt=1, priv=1)
    if h == 'Z7A_0000_0000':
        return cw('HALT', priv=1)
    if h == 'Z7B_0000_0000':
        return cw('IRET', priv=1)
    if h in ('Z7B_0000_1000', 'Z7B_0000_1001', 'Z7B_0000_1010'):
        return cw('NOP', priv=1)
    if h == 'Z7B_dddd_1101':
        return cw('MREQ', priv=1)
    if h == 'Z7C_0000_00ii':
        return cw('DIEI', var=0, priv=1)
    if h == 'Z7C_0000_01ii':
        return cw('DIEI', var=1, priv=1)
    if h == 'Z7D_dddd_0ccc':
        return cw('LDCTL', var=0, priv=1)
    if h == 'Z7D_ssss_1ccc':
        return cw('LDCTL', var=1, priv=1)
    if h == 'Z7F_imm8':
        return cw('TRAPREQ', var=0)
    if h == 'Z36_0000_0000':
        return cw('TRAPREQ', var=1)
    if h in ('Z0E_imm8', 'Z0F_imm8', 'Z8E_imm8', 'Z8F_imm8'):
        return cw('EPU', epu=1)
    if h in ('Z36_imm8', 'Z38_imm8', 'Z78_imm8', 'Z7E_imm8', 'Z9D_imm8', 'Z9F_imm8', 'ZB9_imm8', 'ZBF_imm8', 'Z8D_0000_0111'):
        return cw('NOP')
    flags = {'Z8D_imm4_0001': 0, 'Z8D_imm4_0011': 1, 'Z8D_imm4_0101': 2,
             'Z8C_dddd_0001': 3, 'Z8C_dddd_1001': 4}
    if h in flags:
        return cw('FLAGS', var=flags[h])
    # ---- I/O ---------------------------------------------------------------------
    m = re.match(r'Z3([AB])_\w{4}_(\d{4})', h)
    if m:
        sz = 'B' if m.group(1) == 'A' else 'W'
        code = m.group(2)
        if code in ('0100', '0101'):
            return cw('IO', sz, var=0, nxt=1, priv=1)
        if code in ('0110', '0111'):
            return cw('IO', sz, var=1, nxt=1, priv=1)
        return cw('IO', sz, var=4, nxt=1, priv=1)
    io_reg = {'Z3C_ssss_dddd': ('B', 2), 'Z3D_ssss_dddd': ('W', 2),
              'Z3E_dddd_ssss': ('B', 3), 'Z3F_dddd_ssss': ('W', 3)}
    if h in io_reg:
        sz, var = io_reg[h]
        return cw('IO', sz, var=var, priv=1)
    # ---- shifts and register utilities ---------------------------------------------
    shift = {'ZB2_dddd_00I0': ('B', 0, 0), 'ZB2_dddd_10I0': ('B', 1, 0),
             'ZB2_dddd_01I0': ('B', 2, 0), 'ZB2_dddd_11I0': ('B', 3, 0),
             'ZB3_dddd_00I0': ('W', 0, 0), 'ZB3_dddd_10I0': ('W', 1, 0),
             'ZB3_dddd_01I0': ('W', 2, 0), 'ZB3_dddd_11I0': ('W', 3, 0),
             'ZB2_dddd_0001_imm8': ('B', 4, 1), 'ZB3_dddd_0001_imm8': ('W', 4, 1),
             'ZB3_dddd_0101_imm8': ('L', 4, 1),
             'ZB2_dddd_1001_imm8': ('B', 5, 1), 'ZB3_dddd_1001_imm8': ('W', 5, 1),
             'ZB3_dddd_1101_imm8': ('L', 5, 1),
             'ZB3_dddd_0011_0000_ssss_0000_0000': ('W', 6, 1),
             'ZB3_dddd_0111_0000_ssss_0000_0000': ('L', 6, 1),
             'ZB2_dddd_1011_0000_ssss_0000_0000': ('B', 7, 1),
             'ZB3_dddd_1011_0000_ssss_0000_0000': ('W', 7, 1),
             'ZB3_dddd_1111_0000_ssss_0000_0000': ('L', 7, 1),
             'ZB2_dddd_0011_0000_ssss_0000_0000': ('B', 8, 1)}
    if h in shift:
        sz, var, nxt = shift[h]
        return cw('SHIFT', sz, var=var, nxt=nxt)
    if h == 'ZB0_dddd_0000':
        return cw('DAB', 'B')
    if h == 'ZB1_dddd_0000':
        return cw('EXTS', 'B')
    if h == 'ZB1_dddd_1010':
        return cw('EXTS', 'W')
    if h == 'ZB1_dddd_0111':
        return cw('EXTS', 'L')
    if h in ('ZAE_dddd_cccc', 'ZAF_dddd_cccc'):
        return cw('TCC', 'B' if h[2] == 'E' else 'W')
    if h == 'ZBD_dddd_imm4':
        return cw('LDK')
    if h == 'ZC_dddd_imm8':
        return cw('LDBS', 'B')
    if h == 'ZBC_aaaa_bbbb':
        return cw('RXDB', 'B', var=0)
    if h == 'ZBE_aaaa_bbbb':
        return cw('RXDB', 'B', var=1)
    return None


def encode(c, cycles):
    v = cycles & 0x3ff
    v = (v << 6) | CLS.index(c['cls'])
    v = (v << 2) | SZ[c['sz']]
    v = (v << 5) | AOP.index(c['aop'])
    v = (v << 4) | MODE.index(c['mode'])
    v = (v << 4) | c['var']
    v = (v << 2) | c['nxt']
    v = (v << 1) | c['priv']
    v = (v << 1) | c['epu']
    return v


specs = {}
for e in ENTRIES:
    c = spec(e[5])
    if c is None:
        sys.exit('unclassified handler ' + e[5])
    specs[e[5]] = c

# final first-word -> entry index, exactly as MAME's init_tables builds it
exec_tab = [0] * 65536
for i, (beg, end, step, size, cyc, name) in enumerate(ENTRIES):
    for v in range(beg, end + 1, step):
        exec_tab[v] = i

W = 35
L = []
L.append('// generated by sim/z8002/gen_decode.py from MAME 0.288 z8000tbl.hxx -- do not edit')
for i, n in enumerate(CLS):
    L.append('localparam logic [5:0] C_%s = 6\'d%d;' % (n, i))
for i, n in enumerate(AOP):
    L.append('localparam logic [4:0] A_%s = 5\'d%d;' % (n, i))
for i, n in enumerate(MODE):
    L.append('localparam logic [3:0] M_%s = 4\'d%d;' % (n, i))
L.append('')
L.append('function automatic logic [%d:0] z8k_dec(input logic [15:0] op);' % (W - 1))
L.append('    logic [7:0] lo;')
L.append('    lo = op[7:0];')
L.append("    z8k_dec = %d'h%x;" % (W, encode(specs['zinvalid'], ENTRIES[0][4])))
L.append('    case (op[15:8])')
for hb in range(256):
    lomap = [exec_tab[(hb << 8) | lo] for lo in range(256)]
    if all(x == 0 for x in lomap):
        continue
    # emit runs of identical control words (not entry indices: entries with the
    # same handler and cost encode identically), exact per low byte
    words = [encode(specs[ENTRIES[x][5]], ENTRIES[x][4]) for x in lomap]
    L.append("        8'h%02x: begin" % hb)
    groups = {}
    for lo, w in enumerate(words):
        groups.setdefault(w, []).append(lo)
    default_w = max(groups, key=lambda w: len(groups[w]))
    first = True
    for w, los in groups.items():
        if w == default_w:
            continue
        rng = []
        s0 = p = los[0]
        for x in los[1:]:
            if x == p + 1:
                p = x
                continue
            rng.append((s0, p))
            s0 = p = x
        rng.append((s0, p))
        conds = []
        for a, b in rng:
            if a == b:
                conds.append("lo == 8'h%02x" % a)
            elif a == 0:
                conds.append("lo <= 8'h%02x" % b)
            elif b == 255:
                conds.append("lo >= 8'h%02x" % a)
            else:
                conds.append("(lo >= 8'h%02x && lo <= 8'h%02x)" % (a, b))
        L.append("            %s (%s) z8k_dec = %d'h%x;" % ('if' if first else 'else if', ' || '.join(conds), W, w))
        first = False
    L.append("            %s z8k_dec = %d'h%x;" % ('else' if not first else '', W, default_w))
    L.append('        end')
L.append('        default: ;')
L.append('    endcase')
L.append('endfunction')
L.append('')

# DAB: MAME's 2048-entry result table reduces exactly to the rules below --
# checked here against every entry, so the RTL can carry the rules instead of
# the table. Note the sub cases carry out even when only H was set, and that
# any of H or C on an add gives a flat +0x66: those are MAME's, not Zilog's.
dab = [int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]+)', open(src + '/z8000dab.h').read().split('{', 1)[1])]
assert len(dab) == 2048


def dab_rule(idx):
    v, c, h, d = idx & 0xff, (idx >> 8) & 1, (idx >> 9) & 1, (idx >> 10) & 1
    if not d:
        if h or c:
            return ((v + 0x66) & 0xff) | 0x100
        corr = (6 if (v & 15) > 9 else 0) + (0x60 if v > 0x99 else 0)
        return ((v + corr) & 0xff) | (0x100 if v > 0x99 else 0)
    corr = {0: 0x00, 1: 0xa0, 2: 0xfa, 3: 0x9a}[(h << 1) | c]
    return ((v + corr) & 0xff) | (0x100 if (h or c) else 0)


for i in range(2048):
    if dab_rule(i) != dab[i]:
        sys.exit('DAB rule disagrees with MAME table at %03x' % i)

L.append("""function automatic logic [8:0] z8k_dab(input logic [10:0] idx);
    logic [7:0] v, corr;
    logic       c, h, d, cout;
    v = idx[7:0];
    c = idx[8];
    h = idx[9];
    d = idx[10];
    if (!d) begin
        if (h || c) begin corr = 8'h66; cout = 1'b1; end
        else begin
            corr = ((v[3:0] > 4'd9) ? 8'h06 : 8'h00) + ((v > 8'h99) ? 8'h60 : 8'h00);
            cout = (v > 8'h99);
        end
    end else begin
        case ({h, c})
            2'b00: corr = 8'h00;
            2'b01: corr = 8'ha0;
            2'b10: corr = 8'hfa;
            default: corr = 8'h9a;
        endcase
        cout = h | c;
    end
    z8k_dab = {cout, v + corr};
endfunction""")
open(out, 'w').write('\n'.join(L) + '\n')

# also a C++ view of the classification for the harness (coverage accounting)
with open(sys.argv[3] if len(sys.argv) > 3 else '/dev/null', 'w') as f:
    for i, e in enumerate(ENTRIES):
        f.write('%d %s %s\n' % (i, e[5], specs[e[5]]['cls']))
print('wrote', out, len(ENTRIES), 'entries')
