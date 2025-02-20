from pathlib import Path
from subprocess import Popen, PIPE 

SRC_PATH = Path('gpu4pyscf')

# Walk through src directory
for path_object in SRC_PATH.rglob('*'):
    if path_object.is_file() and path_object.name.endswith('.cu'):
        # Convert found .cu file
        process = Popen(f'hipify-perl {str(path_object)}', stdout=PIPE, shell=True)
        (output, err) = process.communicate()
        lines = []
        for line in output.splitlines(False):
            lines.append(line.decode('ascii'))

        exit_code = process.wait()

        if exit_code != 0:
            print('hipify-perl error!')
            print('\n'.join(lines))
            break

        with open(path_object, 'w') as fd:
            fd.writelines(line + '\n' for line in lines)

        print('Successfully converted {str(path_object)}!')

