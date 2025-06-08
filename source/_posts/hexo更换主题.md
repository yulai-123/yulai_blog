---
title: hexo更换主题
date: 2023-07-20 12:53:03
categories:
- 博客搭建
---
# 背景
hexo 默认主题真丑！！！想要选择一个简约的主题，同时能显示一些个人信息，让博客更加完整。
<!-- more -->
# 目标
1. 更换 hexo 主题
# 过程
## 更换主题
查看了好多个主题，最后在 github 搜索 hexo theme，发现最高star的项目 next 很符合我的口味。next 更加简约，也能够展示我想要的信息，因此选择了 next 主题。

> next 主题有两个仓库，老仓库是个个人仓库，开发了 hexo-theme-next 主题。这个仓库火了之后，开了一个正式的账号theme-next，后续next 主题的更新是在新仓库发布的。

官方文档：[theme-next 安装文档](https://github.com/theme-next/hexo-theme-next/blob/master/docs/INSTALLATION.md)
```shell
# 下载安装最新稳定版
mkdir themes/next
curl -L https://api.github.com/repos/theme-next/hexo-theme-next/tarball/v7.8.0 | tar -zxv -C themes/next --strip-components=1

# 修改 _config.yml，使用next主题
vim _config.yml
------_config.yml
theme: next

# 查看安装结果
hexo clean # 删除以前配置
hexo server --debug
# 访问 4000端口，发现正常访问，符合预期
```

下面是更换效果
<img title="hexo主页" src="/images/1280X1280.PNG" width= 75%>

## 细节配置
接下来是私人习惯配置
参考老的官方文档：[Next 使用文档](http://theme-next.iissnan.com/)

> hexo 里有两个配置文件，hexo自带的_config.yml，为站点配置文件；主题自带文件，如themes/next/_config.yml，为主题配置文件，可以copy到my_blog/目录，作为_config.next.yml文件

这部分就不记录了，比较零碎，适合根据官方文档一点点配置。

## 自动部署

> 这部分超级超级推荐，现在每次本地更新完，一键更新到线上，也不会对博客更新感到厌烦了。

在实际写 blog 时，我先在本地编写和预览，然后上传到服务器进行发布。为了简化上传和部署的流程，写了一个函数来执行。

> 执行时有点报错，不过能用就行，先这样吧

``` shell
# 需要将函数写入 .zshrc 或 .bashrc 文件
# 使用时在本地执行 publish_my_blog
function publish_my_blog() {
    echo "准备发布博客新版本到云服务器..." $(date +%H:%M:%S)
    # 进入 my_blog所在的父目录
    cd /Users/$USER/
    # 压缩文件夹
    tar -czf my_blog.tar.gz my_blog
    #传送文件夹
    # 注意更换端口、用户名、路径
    scp -P 4567 my_blog.tar.gz newname@xx.xx.xx.xx:/home/newname
    # 删除压缩包
    rm my_blog.tar.gz
    echo "博客新版本已经上传云服务器..." $(date +%H:%M:%S)
    echo "准备执行远程命令..." $(date +%H:%M:%S)

    # 注意更换端口、用户名、路径
    # 1. 进入目录
    # 2. 杀掉正在运行的 hexo
    # 3. 删除原来的 my_blog
    # 4. 解压缩
    # 5. 删除压缩包
    # 6. 进入 my_blog
    # 7. 删除缓存
    # 8. 生成模版文件
    # 9. 后台执行
    ssh -p 4567 newname@xx.xx.xx.xx "cd /home/newname; 
        ps -ef | grep hexo | grep -v grep | awk '{print $2}' | sudo xargs kill -9;
        rm -rf /home/newname/my_blog;
        tar -zxf my_blog.tar.gz;
        rm my_blog.tar.gz;
        cd my_blog;
        hexo clean;
        hexo generate;
        nohup sudo hexo server -p 80 -s > /home/newname/myblog.log 2>&1 &"
    echo "云服务器已经执行发布新版本" $(date +%H:%M:%S)
    # 返回原目录
    cd -
}
```

# 参考文档
[九个好看实用的Hexo主题推荐 - 掘金](https://juejin.cn/post/7053744641383874574)
[hexo博客主题推荐](https://segmentfault.com/a/1190000042281398)
[8 款颜值爆赞的 Hexo 主题推荐！快来搭建个人博客玩玩 | Github掘金计划](https://zhuanlan.zhihu.com/p/491537945)
最终选择 next 主题：[GitHub - theme-next/hexo-theme-next: Elegant and powerful theme for Hexo.](https://github.com/theme-next/hexo-theme-next)
