--
-- Train node selection network for bAbI.
--
-- Yujia Li, 10/2015

require 'torch'
require 'optim'
require 'gnuplot'
color = require 'trepl.colorize'

babi_data = require 'babi_data'
eval_util = require 'eval_util'
ggnn = require '../ggnn'

cmd = torch.CmdLine()
cmd:option('-nsteps', 5, 'number of propagation iterations')
cmd:option('-learnrate', 1e-3, 'learning rate')
cmd:option('-momentum', 0, 'momentum')
cmd:option('-mb', 10, 'minibatch size')
cmd:option('-maxiters', 1000, 'maximum number of weight updates')
cmd:option('-printafter', 10, 'print training information after this amount of weight updates')
cmd:option('-saveafter', 100, 'save checkpoint after this amount of weight updates')
cmd:option('-optim', 'adam', 'type of optimization algorithm to use')
cmd:option('-statedim', 4, 'dimensionality of the node representations')
cmd:option('-evaltrain', 0, 'evaluate on training set during training if set to 1')
cmd:option('-nthreads', 1, 'set the number of threads to use with this process')
cmd:option('-ntrain', 100, 'number of training instances')
cmd:option('-nval', 100, 'number of validation instances')
cmd:option('-annotationdim', 1, 'dimensionality of the node annotations')
cmd:option('-outputdir', '.', 'output directory, e.g. exp/q4')
cmd:option('-mode', 'selectnode', 'one of {selectnode, classifygraph, seqclass, shareprop_seqclass}')
cmd:option('-datafile', '', 'should contain lists of edges and questions in standard format')
cmd:option('-seed', 8, 'random seed')
opt = cmd:parse(arg)

print('')
print(opt)
print('')


torch.setnumthreads(opt.nthreads)

------------------------ parameters ----------------------------

state_dim = opt.statedim

prop_net_h_sizes = {}
output_net_h_sizes = {state_dim}
n_steps = opt.nsteps
eval_n_steps = n_steps
minibatch_size = opt.mb
max_iters = opt.maxiters
max_grad_scale = 5
print_after = opt.printafter
save_after = opt.saveafter
plot_after = print_after
eval_train_err = (opt.evaltrain == 1)
-- eval_train_err = false

optfunc = optim[opt.optim]
if optfunc == nil then
    error('Unknown optimization method: ' .. opt.optim)
end

optim_config = {
    learningRate=opt.learnrate, 
    weightDecay=0, 
    momentum=opt.momentum, 
    alpha=0.95,
    maxIter=1,
    maxEval=2,
    dampening=0
}

os.execute('mkdir -p ' .. opt.outputdir)

print('')
print('checkpoints will be saved to [ ' .. opt.outputdir .. ' ]')
print('')
print(optim_config)
print('')

torch.save(opt.outputdir .. '/params', opt)

------------------------ prepare data ---------------------------

math.randomseed(opt.seed)
torch.manualSeed(opt.seed)

all_data = babi_data.load_graphs_from_file(opt.datafile)
--[[ lizx: An example of data_list[i]
    {
        1 : This stores graph data
          {
            1 : first edge
              {
                1 : 1 parent
                2 : 2 edge type
                3 : 2 child
              }
            2 : second edge
              {
                1 : 3
                2 : 2
                3 : 1
              }
          }
        2 : question
          {
            1 :
              {
                1 : 4 question_type
                2 : 1 source
                3 : 2 target
              }
          }
    }
--]]
n_edge_types = babi_data.find_max_edge_id(all_data)
n_tasks = babi_data.find_max_task_id(all_data)
if opt.nval > 0 then
    all_task_train_data, all_task_val_data = babi_data.split_set(all_data, {opt.ntrain, opt.nval}, true)
else
    all_task_train_data = babi_data.split_set(all_data, {opt.ntrain}, true)
    all_task_val_data = all_task_train_data
end

if opt.mode == 'seqclass' or opt.mode == 'shareprop_seqclass' then
    all_task_train_data = babi_data.data_list_to_standard_data_seq(all_task_train_data, opt.annotationdim)
    all_task_val_data = babi_data.data_list_to_standard_data_seq(all_task_val_data, opt.annotationdim)
else -- selectnode, classifygraph
    all_task_train_data = babi_data.data_list_to_standard_data(all_task_train_data, opt.annotationdim)
    all_task_val_data = babi_data.data_list_to_standard_data(all_task_val_data, opt.annotationdim)
end

print(tostring(n_tasks) .. ' tasks in total')
print('')

annotation_dim = opt.annotationdim
print(string.format('%d types of edges in total', n_edge_types))
print(string.format('%d-dimensional annotations for each node', annotation_dim))
print('')

----------------------------- loop over all tasks --------------------------------

-- outer for loop until the end of this file
for task_id=1,n_tasks do

print('')
print('')
print('')
print('=========================== Task ' .. task_id .. ' =================================')
print('')

-- each task is trained seperately

train_data = all_task_train_data[task_id]
val_data = all_task_val_data[task_id]

print(tostring(#train_data) .. ' training examples')
print(tostring(#val_data) .. ' validation examples')
print('')

task_output_dir = opt.outputdir .. '/' .. task_id
os.execute('mkdir -p ' .. task_output_dir)


train_data_loader = babi_data.DataLoader(train_data, true)
val_data_loader = babi_data.DataLoader(val_data, false)

--[[
val_data[1]
{
  1 : edges
    {
      1 :
        {
          1 : 1
          2 : 1
          3 : 2
        }
      2 :
        {
          1 : 2
          2 : 1
          3 : 3
        }
    }
  2 : one-hot encoding of annotations (max_node_id,annotation_dim)
    {
      1 :
        {
          1 : 0
        }
      2 :
        {
          1 : 1
        }
      3 :
        {
          1 : 0
        }
      4 :
        {
          1 : 0
        }
    }
  3 : 1 -- prediction target
}
--]]

------------------------ set up network and training --------------------------

if opt.mode == 'selectnode' then
    model = ggnn.NodeSelectionGGNN(state_dim, annotation_dim, prop_net_h_sizes, output_net_h_sizes, n_edge_types)
elseif opt.mode == 'classifygraph' then
    n_classes = babi_data.find_max_target(train_data)
    output_net_sizes = {state_dim, state_dim, n_classes}
    model = ggnn.GraphLevelGGNN(state_dim, annotation_dim, prop_net_h_sizes, output_net_sizes, n_edge_types)
elseif opt.mode == 'seqclass' then
    n_classes = babi_data.find_max_target(train_data)
    output_net_sizes = {state_dim, state_dim, n_classes}
    glnet = ggnn.GraphLevelGGNN(state_dim, annotation_dim, prop_net_h_sizes, output_net_sizes, n_edge_types)
    anet = ggnn.PerNodeGGNN(state_dim, annotation_dim, prop_net_h_sizes, output_net_h_sizes, n_edge_types)
    model = ggnn.GraphLevelSequenceGGNN(glnet, anet)
elseif opt.mode == 'shareprop_seqclass' then
    n_classes = babi_data.find_max_target(train_data) -- NOTE: there is room for <EOS> symbol
    output_net_sizes = {state_dim, state_dim, n_classes}
    pnet = ggnn.BaseGGNN(state_dim, annotation_dim, prop_net_h_sizes, n_edge_types)
    glnet = ggnn.GraphLevelOutputNet(state_dim, annotation_dim, output_net_sizes)
    anet = ggnn.PerNodeOutputNet(state_dim, annotation_dim, output_net_h_sizes)
    model = ggnn.GraphLevelSequenceSharePropagationGGNN(pnet, glnet, anet)
else
    error('Unknown mode: ' .. opt.mode)
end

params, grad_params = model:getParameters()

criterion = nn.CrossEntropyCriterion()
if ggnn.use_gpu then
    criterion:cuda()
end

model:print_model()
print('number of parameters in the model: ' .. params:nElement())
print('')

optim_state = {}

train_records = {}
train_error_records = {}
val_records = {}

function feval(x)
    if x ~= params then
        params:copy(x)
    end
    grad_params:zero() -- zero out gradient buffer

    local loss = 0

    local edges_list = {}
    local annotations_list = {}
    local target_list = {}

    for i=1,minibatch_size do
        local edges, annotation, target = train_data_loader:next()
        table.insert(edges_list, edges)
        table.insert(annotations_list, annotation)
        table.insert(target_list, target)
    end

    -- this assumes all the targets are of the same size
    local targets = torch.Tensor(target_list)

    --[[ 
        #edges_list[i]: (n_edges,3)
        #targets: (minibatch_size,) for selectnode mode, (minibatch_size,n_pred_steps) for seqclass mode
        #annotations_list[i]: (n_nodes,annotation_dim)
    --]]
    -- forward pass
    if opt.mode == 'seqclass' or opt.mode == 'shareprop_seqclass' then
        output = model:forward(edges_list, targets:size(2), n_steps, annotations_list)
        -- For seqclass mode, output size: (minibatch_size, n_classes * n_pred_steps)
    else -- For selectnode and classify graph
        output = model:forward(edges_list, n_steps, annotations_list)
        -- For selectnode mode, output size: (n_total_nodes,1)
        -- For classifygraph mode, output size: (minibatch_size,n_classes)

    end
    
    local loss
    local output_grad

    if opt.mode == 'selectnode' then
        loss, output_grad = ggnn.compute_node_selection_loss_and_grad(criterion, output, targets, model.n_nodes_list, true)
    elseif opt.mode == 'classifygraph' then
        loss = criterion:forward(output, targets)
        output_grad = criterion:backward(output, targets)
    elseif opt.mode == 'seqclass' or opt.mode == 'shareprop_seqclass' then
        loss, output_grad = ggnn.compute_graph_level_seq_ggnn_loss_and_grad(criterion, output, targets, true)
    end
    
    -- backward pass
    model:backward(output_grad) -- will change grad_params inplace
    if opt.mode == 'selectnode' then
        loss = loss / minibatch_size
        grad_params:div(minibatch_size)
    end

    grad_params:clamp(-max_grad_scale, max_grad_scale)

    return loss, grad_params
end

function train()
    local loss = 0
    local batch_loss = 0
    local iter = 0

    local best_val_err = math.huge
    local best_params = params:clone()

    while iter < max_iters do
        local timer = torch.Timer()
        batch_loss = 0
        for iter_before_print=1,print_after do
            _, loss = optfunc(feval, params, optim_config, optim_state)
            loss = loss[1]
            batch_loss = batch_loss + loss
        end
        iter = iter + print_after
        batch_loss = batch_loss / print_after
        if eval_train_err then
            train_err = eval_util.eval_node_selection(model, train_data, minibatch_size, n_steps)
            table.insert(train_error_records, {iter, train_err})
        end
        if opt.mode == 'selectnode' then
            val_err = eval_util.eval_node_selection(model, val_data, minibatch_size, n_steps)
        elseif opt.mode == 'classifygraph' then
            val_err = eval_util.eval_graph_classification(model, val_data, minibatch_size, n_steps)
        elseif opt.mode == 'seqclass' or opt.mode == 'shareprop_seqclass' then
            val_err = eval_util.eval_seq_classification(model, val_data, minibatch_size, n_steps)
        end
        io.write(string.format('iter %d, grad_scale=%.8f, train_loss=%.6f,%s val_error_rate=%.6f, time=%.2f',
                iter, torch.abs(grad_params):max(), batch_loss, 
                eval_train_err and string.format(' train_error_rate=%.6f,', train_err) or '', val_err, timer:time().real))

        if val_err < best_val_err then
            best_val_err = val_err
            best_params:copy(params)
            ggnn.save_model_to_file(task_output_dir .. '/model_best', model, best_params)
            print(color.green(' *'))
        else
            print('')
        end

        table.insert(train_records, {iter, batch_loss})
        table.insert(val_records, {iter, val_err})

        if iter % save_after == 0 then
            ggnn.save_model_to_file(task_output_dir .. '/model_' .. iter, model, params)
        end

        if iter % plot_after == 0 then
            if not pcall(function () generate_plots() end) then
                print('[Warning] Failed to generate learning curve plots. Error ignored.')
            end
            collectgarbage()
        end
    end

    ggnn.save_model_to_file(task_output_dir .. '/model_end', model, params)
end

function plot_learning_curve(records, fname, ylabel, xlabel)
    xlabel = xlabel or '#iterations'
    local rec = torch.Tensor(records)
    gnuplot.pngfigure(task_output_dir .. '/' .. fname .. '.png')
    gnuplot.plot(rec:select(2,1), rec:select(2,2))
    gnuplot.xlabel(xlabel)
    gnuplot.ylabel(ylabel)
    gnuplot.plotflush()
    collectgarbage()
end

function generate_plots()
    plot_learning_curve(train_records, 'train', 'training loss')
    plot_learning_curve(val_records, 'val', 'validation error rate')
    if eval_train_err then
        plot_learning_curve(train_error_records, 'train-err', 'training error rate')
    end
    collectgarbage()
end

train()

end -- end the loop over tasks

