from execute import *
run('post_docs_docgate',['python',str(P/'tools/run_all.py'),'--strict'])
run('continue_patch_build',['python',str(D/'make_continue_patch.py')])
