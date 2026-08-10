import json, sys

TIERS = ['easy', 'medium', 'hard', 'elite', 'master']
d = json.load(open('/home/eduardo/Documentos/GitHub/rs_tasklocked/task-list.json'))
NULL = '\\N'

def esc(v):
    if v is None:
        return NULL
    s = str(v)
    return (s.replace('\\', '\\\\').replace('\t', '\\t')
             .replace('\n', '\\n').replace('\r', '\\r'))

out = open(sys.argv[1], 'w')
for i, tier in enumerate(TIERS):
    for t in d[tier]:
        tags = t.get('tags')
        tags_s = NULL if not tags else esc('{' + ','.join('"%s"' % x for x in tags) + '}')
        ver = t.get('verification')
        ver_s = NULL if ver is None else esc(json.dumps(ver))
        out.write('\t'.join([
            t['id'], tier, str(i + 1), esc(t['name']), esc(t.get('shortName')),
            esc(t['tip']), esc(t['wikiLink']), esc(t['imageLink']),
            str(t['displayItemId']), ver_s, tags_s,
        ]) + '\n')
out.close()
print('linhas geradas ok')
