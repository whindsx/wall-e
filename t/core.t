use v5.20;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd abs_path);
use JSON::PP qw(encode_json decode_json);
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
    like(call('write',path=>'denied',content=>'oops')->{error},qr/denied/,'deny without terminal');
    ok(!-e 'denied','denied action has no effect');
}
{
    package MockHTTP;
    sub post {
        my ($self,$url,$request)=@_;
        push @{$self->{requests}}, {url=>$url, body=>JSON::PP::decode_json($request->{content})};
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
my $second=$http->{requests}[1]{body};
is($second->{input}[1]{encrypted_content},'opaque','reasoning replayed');
is($second->{input}[3]{call_id},'c1','tool result linked');
is(decode_json(Encode::encode('UTF-8',$second->{input}[3]{output}))->{output},'café','tool Unicode survives nested JSON');
$agent->{max_steps}=1;
$agent->{http}=bless {requests=>[]}, 'MockHTTP';
eval { turn($agent, [], 'read again') };
like($@,qr/Step limit/,'loop budget enforced');
chdir $cwd or die $!;
done_testing;
