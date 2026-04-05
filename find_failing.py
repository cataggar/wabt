import re

def decode_hex_string(s):
    """Decode wasm hex string like \\00asm\\01\\00 into bytes"""
    result = []
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 2 < len(s):
            try:
                byte_val = int(s[i+1:i+3], 16)
                result.append(byte_val)
                i += 3
            except ValueError:
                result.append(ord(s[i]))
                i += 1
        else:
            result.append(ord(s[i]))
            i += 1
    return bytes(result)

with open('third_party/testsuite/binary.wast', 'r') as f:
    content = f.read()
    
lines = content.split('\n')

# Parse assert_malformed blocks with binary modules
i = 0
test_num = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith('(assert_malformed'):
        # Find the full block
        block_lines = []
        depth = 0
        j = i
        while j < len(lines):
            block_lines.append(lines[j])
            depth += lines[j].count('(') - lines[j].count(')')
            if depth <= 0:
                break
            j += 1
        
        block = '\n'.join(block_lines)
        if '(module binary' in block:
            test_num += 1
            # Extract content of (module binary ...) - find the matching paren
            mod_match = re.search(r'\(module binary\s*(.*?)\)', block, re.DOTALL)
            if mod_match:
                mod_content = mod_match.group(1)
                all_bytes = bytearray()
                for mod_line in mod_content.split('\n'):
                    # Remove comments
                    mod_code = mod_line.split(';;')[0]
                    for m in re.finditer(r'"([^"]*)"', mod_code):
                        s = m.group(1)
                        all_bytes.extend(decode_hex_string(s))
                
                size = len(all_bytes)
                if True:  # Show all
                    hex_dump = ' '.join('%02x' % b for b in all_bytes[:20])
                    # Get expected message (last quoted string in block)
                    all_msgs = re.findall(r'"([^"]*)"', block)
                    msg = all_msgs[-1] if all_msgs else '?'
                    print(f'Line {i+1}: {size} bytes, msg="{msg}"')
                    print(f'  hex: {hex_dump}')
        
        i = j + 1
    else:
        i += 1
