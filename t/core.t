use v5.20;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd abs_path);
use JSON::PP qw(encode_json decode_json);
use IO::Socket::INET;
require './wall-e';
my $dir = tempdir(CLEANUP=>1);
my $cwd = getcwd();
chdir $dir or die $!;
my $agent = {yes=>1, timeout=>2, max_steps=>4, model=>'test-model', base=>'http://localhost/v1', key=>'fake', instructions=>'Test'};
sub call { my ($name, %args)=@_; return execute($agent,{name=>$name,arguments=>encode_json(\%args)}) }
is(call('write',path=>'a.txt',content=>"hello café\n")->{output}, 'Written', 'write file');
is(call('read',path=>'a.txt')->{output}, "hello café\n", 'read Unicode');
is(call('edit',path=>'a.txt',old=>'hello',new=>'goodbye')->{output}, 'Written', 'edit');
like(call('edit',path=>'a.txt',old=>'missing',new=>'x')->{error}, qr/not found/, 'missing edit fails');
call('write',path=>'a.txt',content=>'xx');
like(call('edit',path=>'a.txt',old=>'x',new=>'y')->{error}, qr/ambiguous/, 'ambiguous edit fails');
like(call('read',path=>'.')->{error}, qr/regular file/, 'reject directory');
like(call('nope')->{error}, qr/Unknown/, 'unknown tool fails');
my $res = call('shell',command=>'printf hello; printf error >&2; exit 7');
is($res->{output}, 'helloerror', 'capture stdout and stderr');
is($res->{exit_code}, 7, 'exit status');
$agent->{timeout}=0.1;
is(call('shell',command=>'sleep 10')->{stopped}, 'timeout', 'kill timed out command');
$agent->{timeout}=2;
my $large = call('shell',command=>q{perl -e 'print "x" x 70000'});
ok($large->{truncated}, 'large output truncated');
is(length($large->{output}),65536,'output bounded');
# Noninteractive mutation must never implicitly approve or consume input.
{
    local $agent->{yes}=0;
    open my $empty, '<', '/dev/null' or die $!;
    local *STDIN = $empty;
    my $err = call('write',path=>'denied',content=>'oops')->{error};
    like($err,qr/no terminal.*--yes/,'deny without terminal, saying why');
    unlike($err,qr/User denied/,'no-terminal denial not blamed on the user');
    ok(!-e 'denied','denied action has no effect');
    is($agent->{denied},1,'denial counted');
    delete $agent->{denied};
}
{
    package MockHTTP;
    sub post {
        my ($self,$url,$request)=@_;
        push @{$self->{requests}}, {url=>$url, headers=>$request->{headers}, body=>JSON::PP::decode_json($request->{content})};
        my $output = @{$self->{requests}} == 1
            ? [{type=>'reasoning',id=>'r1',summary=>[],encrypted_content=>'opaque'},
               {type=>'function_call',id=>'f1',call_id=>'c1',name=>'read',arguments=>'{"path":"unicode.txt"}'}]
            : [{type=>'message',role=>'assistant',content=>[{type=>'output_text',text=>'Done'}]}];
        return {success=>1,content=>JSON::PP::encode_json({status=>'completed',output=>$output})};
    }
}
write_file('unicode.txt', 'café');
my $http=bless {requests=>[]}, 'MockHTTP';
$agent->{http}=$http;
my @history;
my $printed='';
{
    open my $capture,'>',\$printed or die $!;
    local *STDOUT=$capture;
    turn($agent,\@history,'read it');
}
is($printed,"Done\n",'agent reaches final answer');
is(scalar @{$http->{requests}},2,'tool loop makes follow-up request');
my $first=$http->{requests}[0]{body};
ok(!$first->{store},'stateless requests');
is_deeply($first->{include},['reasoning.encrypted_content'],'request encrypted reasoning');
is($first->{tools}[0]{type},'function','Responses tool schema');
is_deeply([map { $_->{name} } @{$first->{tools}}],[qw(read write edit shell)],'all tools offered by default');
is_deeply([map { $_->{name} } @{tools(1)}],['read'],'read-only offers only read');
my $second=$http->{requests}[1]{body};
is($second->{input}[1]{encrypted_content},'opaque','reasoning replayed');
is($second->{input}[3]{call_id},'c1','tool result linked');
is(decode_json(Encode::encode('UTF-8',$second->{input}[3]{output}))->{output},'café','tool Unicode survives nested JSON');
is($http->{requests}[0]{headers}{Authorization},'Bearer fake','key sent as bearer token');
{
    local $agent->{key};
    local $agent->{http}=bless {requests=>[]}, 'MockHTTP';
    open my $sink,'>',\my $ignored or die $!;
    local *STDOUT=$sink;
    turn($agent,[],'no key');
    ok(!exists $agent->{http}{requests}[0]{headers}{Authorization},'no Authorization header without key');
}
{
    local $ENV{WALLE_API_KEY}='secret-value';
    is(call('shell',command=>'printf "%s" "${WALLE_API_KEY-unset}"')->{output},'unset','key hidden from shell commands');
}
$agent->{max_steps}=1;
$agent->{http}=bless {requests=>[]}, 'MockHTTP';
eval { turn($agent, [], 'read again') };
like($@,qr/Step limit/,'loop budget enforced');
is(check_base('https://api.example.com/v1/'), 'https://api.example.com/v1', 'HTTPS accepted, slash trimmed');
is(check_base('http://localhost:8080/v1'), 'http://localhost:8080/v1', 'HTTP localhost accepted');
like((eval { check_base('http://gpu-box:8080/v1') }, $@), qr/--allow-http/, 'remote HTTP refused by default');
like((eval { check_base('http://localhost.evil.com/v1') }, $@), qr/--allow-http/, 'localhost prefix is not local');
like((eval { check_base('ftp://gpu-box/v1', 1) }, $@), qr/https:\/\//, 'other schemes refused');
{
    my $warn = '';
    open my $err, '>', \$warn or die $!;
    local *STDERR = $err;
    is(check_base('http://gpu-box:8080/v1', 1), 'http://gpu-box:8080/v1', 'remote HTTP allowed explicitly');
    like($warn, qr/cleartext/, 'explicit HTTP warns');
}
# Terminal Markdown rendering.
sub plain { my $t = render_markdown(@_); $t =~ s/\e\[[0-9;]*m//g; return $t }
is(render_markdown('**hi** `x`'), "\e[1mhi\e[22m \e[36mx\e[39m\n", 'bold and code spans styled');
is(plain("# Title\n- item"), "Title\n• item\n", 'heading marks removed, bullets drawn');
is(plain("`**raw**` and snake_case_name and 2*3*4"), "**raw** and snake_case_name and 2*3*4\n", 'code spans and stray markers untouched');
is(plain("```perl\nmy \$x = '**y**';\n```"), "    my \$x = '**y**';\n", 'fences dropped, code indented verbatim');
is(plain("| A | Bee |\n|---|:---:|\n| long | 1 |"), "A    │ Bee\n─────┼────\nlong │ 1\n", 'table aligned, divider redrawn');
is(plain('See [docs](https://x.y).'), "See docs (https://x.y).\n", 'link shows text and URL');
# End to end: run the executable against a local server that asks for one write.
sub serve {
    my @bodies = @_;
    my $server = IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>0, Listen=>5, ReuseAddr=>1) or die $!;
    my $pid = fork() // die $!;
    if (!$pid) {
        for my $body (@bodies) {
            my $c = $server->accept or last;
            my $len = 0;
            while (my $line = <$c>) { $len = $1 if $line =~ /^Content-Length:\s*(\d+)/i; last if $line eq "\r\n" }
            read $c, my $ignored, $len;
            print {$c} "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ", length($body), "\r\nConnection: close\r\n\r\n", $body;
            close $c;
        }
        POSIX::_exit(0);
    }
    return ($pid, 'http://127.0.0.1:' . $server->sockport . '/v1');
}
sub run_walle {
    my ($base, @args) = @_;
    my $out = `WALLE_BASE_URL=$base WALLE_MODEL=m '$cwd/wall-e' @args </dev/null 2>&1`;
    return ($? >> 8, $out);
}
my $write_call = encode_json({status=>'completed', output=>[{type=>'function_call',id=>'f',call_id=>'c',name=>'write',arguments=>'{"path":"e2e.txt","content":"x"}'}]});
my $final = encode_json({status=>'completed', output=>[{type=>'message',role=>'assistant',content=>[{type=>'output_text',text=>'Done'}]}]});
{
    my ($pid, $base) = serve($write_call, $final);
    my ($code, $out) = run_walle($base, "'write a file'");
    waitpid $pid, 0;
    is($code, 2, 'one-shot exits 2 when an action was denied');
    like($out, qr/1 tool call\(s\) denied.*--yes/, 'denial reported');
    like($out, qr/Read-only/, 'read-only mode announced');
    ok(!-e 'e2e.txt', 'denied write did not happen');
}
{
    my ($pid, $base) = serve($write_call, $final);
    my ($code) = run_walle($base, '--yes', "'write a file'");
    waitpid $pid, 0;
    is($code, 0, 'one-shot exits 0 when actions ran');
    ok(-e 'e2e.txt', 'approved write happened');
}
chdir $cwd or die $!;
done_testing;
