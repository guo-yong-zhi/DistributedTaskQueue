DistributedTaskQueue
===
如果有大量的任务，也有多个分布式的worker，我们该如何进行合理的分配？  
If there are a large number of tasks and multiple distributed workers, how can we reasonably allocate them?  
手动将m个任务写到n个sh文件然后在n个worker中分别执行？这种静态方案缺点明显：1.操作繁琐 2.很难分配均匀 3.不能动态增加新的任务 4.不能动态增加新的worker。总之这种手动方案灵活性不足。  
Manually write m tasks to n .sh files and then execute them in n workers respectively? The disadvantages of this static scheme are obvious: 1. Cumbersome; 2. It is difficult to distribute evenly; 3. New tasks cannot be added dynamically; 4. New workers cannot be added dynamically. In short, this manual scheme is not flexible enough.  
理想的解决方案是实现一个分布式的任务队列，新的任务append到队尾，各worker动态地消费队列中的任务。  
The ideal solution is to implement a distributed task queue. New tasks are appended to the end of the queue, and workers consume them dynamically.  
有一些这样的工具，但它们都采用了Redis等方案来实现分布式锁，因此都非常复杂，依赖多，安装麻烦，上手难。  
There are some such tools, but they all use solutions such as Redis to implement distributed locks, so they are very complex, have many dependencies, and are difficult to install and get started.  
这里提供一个免安装的单文件的解决方案，只有200多行代码。该方案基于`bash`、`ssh`和`python3`，基本原理是master节点保存一份任务清单（文本文件），各worker节点通过ssh连接到master，在master上使用`flock`命令完成加解锁，并使用python完成对任务清单文件的编辑，最后返回任务项（以字符串）到worker，在worker上执行具体命令。master需安装python3用于字符串处理，但不需要安装任何python包。任务队列以文本文件的形式存在，通过直接编辑文件的方式管理任务，不需要特殊的命令。master节点不运行任何专门的监听进程，不占用任何通信端口，不需要配置worker的信息。所有的通信通过从worker到master的单向ssh会话完成。  
Here is an installation-free, single-file solution with just over 200 lines of code. The scheme is based on `bash`, `ssh` and `python3`. Basic flow: 1.The master node keeps a task list (text file) 2. The worker nodes connect to the master via ssh 3.On the master, use the `flock` command to lock the task list file, and use python to edit file, and finally return the task item (as a string) to the worker. 4. Execute specific commands on the worker. python3 is required on master for string processing, but any 3rd party packages are not required. The task queue is a text file. So no special commands are required to manage tasks, and you can edit the file directly. On the master node, no special monitoring process is run, no communication port is occupied. Master knows nothing about workers, and all information is exchanged through a one-way SSH session from the worker to the master.  
## 一、第一个例子 A simple example
### 下载 Download
先下载脚本到各worker上。  
First, download the script to each worker.  
```shell
cd ~
wget https://raw.githubusercontent.com/guo-yong-zhi/DistributedTaskList/main/runtask.sh
chmod a+x ~/runtask.sh
```
注：`~/runtask.sh -h`可以查看帮助信息  
Note: Use `~/runtask.sh -h` to view help information  
### 新建任务文件 Create a new task file
在master节点磁盘上新建任务文件，例如`~/examplelist.sh`。每一行为一个任务项，master节点不会真正执行这些命令，它们会被分配到不同worker上执行。master上不需要有执行这些命令所需的环境。  
Create a new task file on the master node disk, such as `~/examplelist.sh`, one task item per line. The master node will not actually execute these commands, commands will be assigned to workers. The master does not need to have a corresponding environment.  
```shell
echo task1; sleep 3 
echo task2; sleep 3 
echo task3; sleep 3
echo task4; sleep 3 
echo task5; sleep 3 
```
### runtask
然后在各worker上分别执行以下命令，新的worker可以在任何时候加入  
Then execute the following command on each worker. New workers can join at any time.  
```shell
~/runtask.sh ~/examplelist.sh -m "master@myhost"
```
or, equivalently:
```shell
~/runtask.sh master@myhost:~/examplelist.sh
```
位置参数`~/examplelist.sh`是master节点上的文件路径，并不一定存在于worker上。  
The positional parameter `~/examplelist.sh` is the file path on the master node, which may not exist on the worker.  
关键字参数`-m`用于指定master节点，请用你server的地址替换上述命令中的字符串。worker必须能通过ssh免密码连接到该master节点，需要添加ssh key。   
The keyword argument `-m` is used to specify the address of the master, please replace the string with your server. The worker must be able to log in to the master with password-free ssh. So you may need to configure ssh key.  
运行过程中任务从上往下依次执行，`~/examplelist.sh`会被自动编辑，任务项会被一行行消费掉（注释掉）。worker-id、运行时间等信息会被添加。示例如下：  
During the running process, the tasks are executed sequentially from top to bottom. `~/examplelist.sh` will be automatically edited and task items will be consumed (commented out) line by line. Information such as worker-id, running time, etc. will be added. An example is as follows:  
```shell
#LASTWORKER 1
#echo task1; sleep 3 # worker 0 # (07-28 15:52:29 ... 07-28 15:52:33) #ok
#echo task2; sleep 3 # worker 0 # (07-28 15:52:33 ...
#echo task3; sleep 3 # worker 1 # (07-28 15:52:34 ...
echo task4; sleep 3 
echo task5; sleep 3 
# worker 0: myspace-g46kh-25239-worker-0 100.122.27.103  (07-28 15:52:28)
# worker 1: myspace-khg46-39252-worker-0 100.121.27.101  (07-28 15:52:34)
```
## 二、一个任务实例 A practical example
下面是一个训练多个深度学习模型的例子。假设有目录结构  
An example of training a series of deep learning models is as follows. Suppose the directory structure is like:  
>~/playground/models  
|- resnet_family  
|  |- resnet18  
|  |- resnet34  
|  |- resnet50  
|  
|- mbnet_family  
|  |- mbnetv1  
|  |- mbnetv2  
|  |- mbnetv3  

### 新建任务文件  Create a new task file
新建`~/tasklist.sh`如下:  
Create a new `~/tasklist.sh` as follows:  
```shell
cd ~/playground/models/resnet_family #!
resnet18; train_model #@1
resnet34; train_model
resnet50; train_model
resnet18; test_model #@1
cd ../mbnet_family #!
mbnetv1; train_model
mbnetv2; train_model
mbnetv3; train_model
```
有`#!`标记的行用于环境初始化，没有`#!`标记的行是具体的任务。  
为了安排顺序敏感的任务，这里通过`#@1`标签指定它们都在worker 1上运行。[see tags](#tags)  
Lines marked with `#!` are used for environment initialization, and lines without `#!` mark are specific training/testing tasks.  
To schedule order-sensitive tasks, the `#@1` tag here specifies that they all run on worker 1. [see tags](#tags)
### 配置环境变量 Configure environment variables  
```shell
export MASTER_SERVER="master@myhost"
```
这里同样需要用你server的地址完成替换。可以根据你使用的shell添加到`~/.bashrc`、`~/.zshrc`等配置文件中。[see 环境变量和运行时变量](#环境变量和运行时变量)  
Here you also need to replace the string with the address of your server. It can be added to `~/.bashrc`, `~/.zshrc` or other configuration files according to the shell you use. [see 环境变量和运行时变量](#环境变量和运行时变量)  
### runtask
在各worker上分别执行以下命令，此处`-m`可以省略了。  
Execute the following command on each worker. Note that `-m` can be omitted here.  
```shell
~/runtask.sh ~/tasklist.sh
```
## 三、其它 other instructions
### lock
任务运行时若直接手动编辑任务文件可能引起冲突（除非你确信在此期间worker忙于执行当前任务，不会来读取下一个任务），因此编辑前需先执行命令如`~/runtask.sh ~/tasklist.sh --lock`，在编辑完后再`CTRL-C`释放。编辑时可以追加新任务，删除未执行的任务或改变其顺序，但尽量不要在已经开始的任务前增减内容（即改变其行号）。  
Manually editing the task file may cause conflicts when the tasks are running (unless you are sure that the worker is busy executing the current task and will not fetch the next task item), so you'd better run a lock command such as `~/runtask.sh ~/tasklist.sh --lock` before editing, and release it with `CTRL-C` after editing. It is ok to append new tasks, delete pending tasks or change their order, but it is best not to add or subtract content before tasks that have already started. (ie change their line numbers)   
### reset
运行过程中任务文件会被编辑加入很多注释，如果想要重新跑任务，执行如`~/runtask.sh ~/tasklist.sh --reset`，可以还原任务文件到未运行状态。
During the running process, the task file will be edited and added with many comments. If you want to run the task again, execute such as `~/runtask.sh ~/tasklist.sh --reset`, and the task file will be restored to the non-running state.  
### tags
任务文件支持两种tag，`#!`和`#@i`。  
Two types of tags are supported in task files, `#!` and `#@i`.  
有`#!`标签的行会被所有可能的worker执行，且其中的`cd`等命令会影响脚本环境，常用作初始化；没有`#!`标记的行仅会被一个worker执行（之后会被注释掉），且是在子shell中执行，其中的`cd`等命令不会影响父环境，常用作执行具体任务。  
Lines with `#!` tags will be executed by all possible workers, and commands such as `cd` will affect the environment and are often used for initialization; Lines without `#!` tags will only be executed by one worker (and then commented out), and will be executed in a subshell. Commands such as `cd` do not affect the parent environment, and are often used to run specific tasks.  
有`#@i`标签的行会指定在某个worker上运行，`i`为worker-id。多个备选worker可以写多个标签，如`#@1#@2`。如果和`#!`连用，如`#!#@1#@2`，则每一个worker都会执行该任务。没有`#@i`标签意味着可以在任何worker上执行，等价于该行有所有worker的标签。  
Tasks tagged with `#@i` will be specified to run on a certain worker, where `i` is the worker-id. Multiple tags such as `#@1#@2` represent multiple alternative workers. If it is used with `#!`, such as `#!#@1#@2`, every worker will execute the task. No `#@i` tag means it can be executed on all workers, which is equivalent to having tags of all workers.  
### 环境变量和运行时变量 Environment variables and runtime variables
可以在worker里（master节点不需要）配置环境变量`MASTER_SERVER`、`WORKER_NAME`、`TASK_FILE`。配置了环境变量，在命令行运行`~/runtask.sh`时就可以省略相应的参数。另有环境变量`WORKERID`可以读取，但不可配置。worker-id一般自动生成，如需配置可通过命令行参数`--id`或运行时变量`newid`。  
Environment variables `MASTER_SERVER`, `WORKER_NAME`, `TASK_FILE` can be configured in the worker (not necessary for the master node). With environment variables configured, the corresponding parameters can be omitted when running `~/runtask.sh` on the command line. Another environment variable `WORKERID` can be read, but not set. The worker-id is usually generated automatically, but you can also set it via the command line argument `--id` or the runtime variable `newid`.  
有两个重要的运行时变量`newtask`和`newid`可以用于在任务过程中设置新的任务文件和worker-id，前者对应环境变量`TASK_FILE`和位置命令行参数，后者对应环境变量`WORKERID`和命令行参数`-i`、`--id`。  
There are two important runtime variables `newtask` and `newid` that can be used to set new task file and worker-id on the fly. The former corresponds to the environment variable `TASK_FILE` and the positional command line parameter, and the latter corresponds to the environment variable `WORKERID` and command line arguments `-i`, `--id`.  
利用这些变量可以完成任务文件跳转，下面是个例子（`~/tasklist1.sh`）：  
Using these variables, you can achieve dynamic task file jumping. Here is an example (`~/tasklist1.sh`):  
```shell
echo task1; sleep 3 
echo task2; sleep 3 
echo task3; sleep 3
echo task4; sleep 3
exit #!#@1
newtask="~/tasklist2.sh" #!#@2
newtask="~/tasklist3.sh"; newid=$WORKERID #!
echo task5; sleep 3
```
注意想要改变执行流时标签`#!`是必需的。上例task1至task4执行完后，worker 1将直接退出；worker 2将跳转至`~/tasklist2.sh`，并会重新分配一个worker-id；其余worker将跳转至`~/tasklist3.sh`并保持worker-id不变。task5将永远执行不到。 
Note that the tag `#!` is required when you want to change the execution flow. After task1 to task4 are executed, worker 1 will exit directly; worker 2 will jump to `~/tasklist2.sh`, and will be reassigned a new worker-id; other workers will jump to `~/tasklist3.sh` And keep the worker-id unchanged. task5 will never be executed.  
