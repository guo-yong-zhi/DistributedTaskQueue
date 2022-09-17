DistributedTaskQueue
===
If there are a large number of tasks and multiple distributed workers, how can we reasonably allocate them?  
Manually write m tasks to n .sh files and then execute them in n workers respectively? The disadvantages of this static scheme are obvious: 1. Cumbersome; 2. It is difficult to distribute evenly; 3. New tasks cannot be added dynamically; 4. New workers cannot be added dynamically. In short, this manual scheme is not flexible enough.  
The ideal solution is to implement a distributed task queue. New tasks are appended to the end of the queue, and workers consume them dynamically.  
There are some such tools, but they all use solutions such as Redis to implement distributed locks, so they are very complex, have many dependencies, and are difficult to install and get started.   
Here is an installation-free, single-file solution with just over 200 lines of code. The scheme is based on `bash`, `ssh` and `python3`. Basic flow: 1.The master node keeps a task list (text file) 2. The worker nodes connect to the master via ssh 3.On the master, use the `flock` command to lock the task list file, and use python to edit file, and finally return the task item (as a string) to the worker. 4. Execute specific commands on the worker. python3 is required on master for string processing, but any 3rd party packages are not required. The task queue is a text file. So no special commands are required to manage tasks, and you can edit the file directly. On the master node, no special monitoring process is run, no communication port is occupied. Master knows nothing about workers, and all information is exchanged through a one-way SSH session from the worker to the master.  
## A simple example
### Download 
First, download the script to each worker.  
```shell
cd ~
wget https://raw.githubusercontent.com/guo-yong-zhi/DistributedTaskQueue/main/runtask.sh
chmod a+x ~/runtask.sh
```
Note: Use `~/runtask.sh -h` to view help information  
### Create a new task file
Create a new task file on the master node disk, such as `~/examplelist.sh`, one task item per line. The master node will not actually execute these commands, commands will be assigned to workers. The master does not need to have a corresponding environment.  
```shell
echo task1; sleep 3 
echo task2; sleep 3 
echo task3; sleep 3
echo task4; sleep 3 
echo task5; sleep 3 
```
### runtask 
Then execute the following command on each worker. New workers can join at any time.  
```shell
~/runtask.sh ~/examplelist.sh -m "master@myhost"
```
or, equivalently:
```shell
~/runtask.sh master@myhost:~/examplelist.sh
```  
The positional parameter `~/examplelist.sh` is the file path on the master node, which may not exist on the worker.   
The keyword argument `-m` is used to specify the address of the master, please replace the string with your server. The worker must be able to log in to the master with password-free ssh. So you may need to configure ssh key.    
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
## A practical example
An example of training a series of deep learning models is as follows. Suppose the directory structure is like:  
>~/playground/models  
|- resnet_family   
|  |- resnet34  
|  |- resnet50  
|  |- resnet101  
|  
|- mbnet_family  
|  |- mbnetv1  
|  |- mbnetv2  
|  |- mbnetv3  

### Create a new task file
Create a new `~/tasklist.sh` as follows:  
```shell
cd ~/playground/models/resnet_family #!
cd resnet34; train_model #:mygroup1
cd resnet50; train_model
cd resnet101; train_model #@2

cd ../mbnet_family #!
cd mbnetv1; train_model
cd mbnetv2; train_model
cd mbnetv3; train_model

cd ../resnet_family #!
cd resnet34; deploy_model #:mygroup1
cd resnet34; test_model_on dataset1 #+mygroup1
cd resnet34; test_model_on dataset2 #+mygroup1
cd resnet34; test_model_on dataset3 #+mygroup1
cd resnet34; report_test_result #:mygroup1
```
Lines marked with `#!` are used for environment initialization, and lines without `#!` are specific training/testing tasks.  
`#@2` tag here specifies that the big resnet101 will be trained on worker 2 (because my worker 2 has more memory).
```
                                +--> test_model_on dataset1 ---+
                                |                              |
train_model --> deploy_model ---+--> test_model_on dataset2 ---+--> report_test_result
                                |                              |
                                +--> test_model_on dataset3 ---+
```
To schedule order-sensitive tasks, we use tags `#:name` (sequential) and `#+name` (parallel).  [see tags](#tags)
### Configure environment variables  
```shell
export MASTER_SERVER="master@myhost"
```  
Here you also need to replace the string with the address of your server. It can be added to `~/.bashrc`, `~/.zshrc` or other configuration files according to the shell you use. [see Environment variables and runtime variables](#environment-variables-and-runtime-variables)  
### runtask  
Execute the following command on each worker. Note that `-m` can be omitted here.  
```shell
~/runtask.sh ~/tasklist.sh
```
## other instructions
### lock
Manually editing the task file may cause conflicts when the tasks are running (unless you are sure that the worker is busy executing the current task and will not fetch the next task item), so you'd better run a lock command such as `~/runtask.sh ~/tasklist.sh --lock` before editing, and release it with `CTRL-C` after editing. It is ok to append new tasks, delete pending tasks or change their order, but it is best not to add or subtract content before tasks that have already started. (ie change their line numbers)   
### reset
During the running process, the task file will be edited and added with many comments. If you want to run the task again, execute such as `~/runtask.sh ~/tasklist.sh --reset`, and the task file will be restored to the non-running state.  Use `--reset k` to partially reset the lines after line `k`.
### tags 
Four types of tags are supported in task files, `#!`, `#@i`, `#:group1` and `#+group1`.    
* `#!`    
Lines with `#!` tags will be executed by all possible workers, and commands such as `cd` will affect the environment and are often used for initialization; Lines without `#!` tags will only be executed by one worker (and then commented out), and will be executed in a subshell. Commands such as `cd` do not affect the parent environment, and are often used to run specific tasks.    
* `#@`    
Tasks tagged with `#@i` will be specified to run on a certain worker, where `i` is the worker-id. Multiple tags such as `#@1#@2` represent multiple alternative workers. If it is used with `#!`, such as `#!#@1#@2`, every worker will execute the task. No `#@i` tag means it can be executed on all workers, which is equivalent to having tags of all workers.  
* `#:` and `#+`  
Tags `#:group1` and `#+group1` are used to bind some command lines to one group. "group1" can be replaced with any name you like. A line marked with `#:group1` will not start to run until the commands before marked with `#:group1` or `#+group1` (commands in the same group) finish and succeed (labeled with `#ok`). A line marked with `#+group1` will not start to run until the commands before marked with `#:group1` finish and succeed. That is, `#+` marked lines do not wait for each other, so they can be executed in parallel.
### Environment variables and runtime variables
Environment variables `MASTER_SERVER`, `WORKER_NAME`, `TASK_FILE` can be configured in the worker (not necessary for the master node). With environment variables configured, the corresponding parameters can be omitted when running `~/runtask.sh` on the command line. Another environment variable `WORKERID` can be read, but not set. The worker-id is usually generated automatically, but you can also set it via the command line argument `--id` or the runtime variable `newid`.  
There are three important runtime variables `newtask`, `newid`  and `jumpto` that can be used to set new task file and worker-id on the fly. `newtask` corresponds to the environment variable `TASK_FILE` and the positional command line parameter, and `newid` corresponds to the environment variable `WORKERID` and command line arguments `-i`, `--id`.   
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
Note that the tag `#!` is required when you want to change the execution flow. After task1 to task4 are executed, worker 1 will exit directly; worker 2 will jump to `~/tasklist2.sh`, and will be reassigned a new worker-id; other workers will jump to `~/tasklist3.sh` and keep the worker-id unchanged. task5 will never be executed.  Setting both `newtask` and `newid` is a common pattern, so here's a shorthand `jumpto`. That is, `newtask="~/tasklist3.sh"; newid=$WORKERID #!` is equivalent to `jumpto="~/tasklist3.sh" #!`
