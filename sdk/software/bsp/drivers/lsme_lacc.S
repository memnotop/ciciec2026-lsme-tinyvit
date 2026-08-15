    .section .text
    .align 2

    // 为每条自定义指令生成一个可被 C 调用的普通函数符号。
    // 进入函数时 a0/a1 已保存参数；.word 执行自定义指令，随后 jirl 返回调用者。
    .macro LSME_FN name, encoding
    .globl \name
    .type  \name, @function
\name:
    .word  \encoding
    jirl   $r0, $r1, 0
    .size  \name, .-\name
    .endm

    // rd=a0(r4)，无源操作数。
    LSME_FN lsme_lacc_ctrl_query,   0xc0000004
    LSME_FN lsme_lacc_ctrl_start,   0xc0008004
    LSME_FN lsme_lacc_ctrl_clear,   0xc0018004

    // rj=a0(r4)，rk=a1(r5)，rd=a0(r4)。
    LSME_FN lsme_lacc_ldz_z0,       0xc0401484
    LSME_FN lsme_lacc_ldzt_z1,      0xc0449484

    // rj=a0(r4)，rd=a0(r4)。
    LSME_FN lsme_lacc_pset_p0,      0xc0800084
    LSME_FN lsme_lacc_pset_p1,      0xc0808084
    LSME_FN lsme_lacc_smopa,        0xc1000084
    LSME_FN lsme_lacc_bias_za0,     0xc0e00084

    LSME_FN lsme_lacc_zero_za0,     0xc0c08004
    LSME_FN lsme_lacc_stza_s32,     0xc1401484
    LSME_FN lsme_lacc_stza_i8,      0xc1421484
    LSME_FN lsme_lacc_stza_i8_relu, 0xc1461484
    // EXEC 只提交描述符并立即返回；WAIT 会阻塞到描述符执行结束。
    LSME_FN lsme_lacc_exec,         0xc1800084
    LSME_FN lsme_lacc_wait,         0xc1c00004
